import Cocoa
import ReSwift

enum ScreenViewAction: Action {
    case setDisplayID(CGDirectDisplayID)
}

class ScreenViewController: SubscriberViewController<ScreenViewData>, NSWindowDelegate {
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(didClickOnScreen)))
    }

    private var display: CGVirtualDisplay!
    private var stream: CGDisplayStream?
    private var isWindowHighlighted = false
    private var previousResolution: CGSize?
    private var previousScaleFactor: CGFloat?
    private var hasSizedWindowInitially = false

    override func viewDidLoad() {
        super.viewDidLoad()

        // Without the Screen Recording permission the stream delivers nothing and the window
        // stays blank, and macOS doesn't ask by itself: the app has to, or it never shows up in
        // the Screen Recording list. Ask (the system prompt also lists DeskPad there) and say
        // in the window what to do.
        if CGPreflightScreenCaptureAccess() == false {
            _ = CGRequestScreenCaptureAccess()
            showPermissionHint()
        }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "DeskPad Display"
        descriptor.maxPixelsWide = 5120
        descriptor.maxPixelsHigh = 2160
        descriptor.sizeInMillimeters = CGSize(width: 1600, height: 1000)
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x3456
        descriptor.serialNum = 0x0001

        let display = CGVirtualDisplay(descriptor: descriptor)
        store.dispatch(ScreenViewAction.setDisplayID(display.displayID))
        self.display = display

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        var modes = availableResolutions.map {
            CGVirtualDisplayMode(width: UInt($0.size.width), height: UInt($0.size.height), refreshRate: 60)
        }

        // Make sure the built-in display's exact resolution is selectable, so we can
        // default the virtual display to match it (see ScreenConfigurationSideEffect).
        if
            let builtInPointSize = NSScreen.builtIn?.frame.size,
            !modes.contains(where: { $0.width == UInt(builtInPointSize.width) && $0.height == UInt(builtInPointSize.height) })
        {
            modes.insert(
                CGVirtualDisplayMode(width: UInt(builtInPointSize.width), height: UInt(builtInPointSize.height), refreshRate: 60),
                at: 0
            )
        }

        settings.modes = modes
        display.apply(settings)
    }

    override func update(with viewData: ScreenViewData) {
        if viewData.isWindowHighlighted != isWindowHighlighted {
            isWindowHighlighted = viewData.isWindowHighlighted
            view.window?.backgroundColor = isWindowHighlighted
                ? NSColor.selectedContentBackgroundColor
                : NSColor.windowBackgroundColor
        }

        if
            viewData.resolution != .zero,
            viewData.resolution != previousResolution
            || viewData.scaleFactor != previousScaleFactor
        {
            previousResolution = viewData.resolution
            previousScaleFactor = viewData.scaleFactor
            stream = nil
            if hasSizedWindowInitially == false {
                hasSizedWindowInitially = true
                view.window?.setContentSize(quarterScreenSize(fitting: viewData.resolution))
            } else {
                view.window?.setContentSize(viewData.resolution)
            }
            view.window?.contentAspectRatio = viewData.resolution
            view.window?.center()
            dispatchWindowContentFrame()
            let stream = CGDisplayStream(
                dispatchQueueDisplay: display.displayID,
                outputWidth: Int(viewData.resolution.width * viewData.scaleFactor),
                outputHeight: Int(viewData.resolution.height * viewData.scaleFactor),
                pixelFormat: 1_111_970_369,
                properties: [
                    CGDisplayStream.showCursor: true,
                ] as CFDictionary,
                queue: .main,
                handler: { [weak self] _, _, frameSurface, _ in
                    if let surface = frameSurface {
                        self?.view.layer?.contents = surface
                    }
                }
            )
            self.stream = stream
            stream?.start()
        }
    }

    func windowDidMove(_: Notification) {
        keepWindowOffVirtualDisplay()
        dispatchWindowContentFrame()
    }

    // The virtual display has no monitor, so a preview window that ends up on it is
    // invisible — and it would mirror itself. Dragging the window across a display edge
    // that macOS connects, or flicking it there, can carry it over. So its centre is
    // never allowed onto the virtual display: it stops at the edge of the real displays
    // like at a wall (clamping, not snapping back, so there's no visible jump).
    private func keepWindowOffVirtualDisplay() {
        guard
            let window = view.window,
            let displayID = store.state.screenConfigurationState.displayID,
            let virtualScreen = NSScreen.screens.first(where: { $0.displayID == displayID }),
            NSMouseInRect(CGPoint(x: window.frame.midX, y: window.frame.midY), virtualScreen.frame, false)
        else { return }

        let realFrames = NSScreen.screens.filter { $0.displayID != displayID }.map(\.frame)
        guard var realBounds = realFrames.first else { return }
        for frame in realFrames.dropFirst() {
            realBounds = realBounds.union(frame)
        }

        // Centre kept one point inside the real displays' bounds.
        let size = window.frame.size
        window.setFrameOrigin(CGPoint(
            x: min(max(window.frame.minX, realBounds.minX - size.width / 2 + 1), realBounds.maxX - size.width / 2 - 1),
            y: min(max(window.frame.minY, realBounds.minY - size.height / 2 + 1), realBounds.maxY - size.height / 2 - 1)
        ))
    }

    func windowDidResize(_: Notification) {
        dispatchWindowContentFrame()
    }

    // Sizes the window to fit within a quarter of the screen's visible area on
    // first launch, preserving the virtual display's aspect ratio, rather than
    // opening at the resolution's full point size.
    private func quarterScreenSize(fitting resolution: CGSize) -> CGSize {
        guard let visibleFrame = (view.window?.screen ?? NSScreen.main)?.visibleFrame else {
            return resolution
        }
        let maxSize = CGSize(width: visibleFrame.width / 2, height: visibleFrame.height / 2)
        let scale = min(maxSize.width / resolution.width, maxSize.height / resolution.height)
        return CGSize(width: resolution.width * scale, height: resolution.height * scale)
    }

    private func dispatchWindowContentFrame() {
        guard let window = view.window else { return }
        let contentFrame = window.contentRect(forFrameRect: window.frame)
        store.dispatch(PreviewWindowAction.setContentFrame(contentFrame))
    }

    func windowWillResize(_ window: NSWindow, to frameSize: NSSize) -> NSSize {
        let snappingOffset: CGFloat = 30
        let contentSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        guard
            let screenResolution = previousResolution,
            abs(contentSize.width - screenResolution.width) < snappingOffset
        else {
            return frameSize
        }
        return window.frameRect(forContentRect: NSRect(origin: .zero, size: screenResolution)).size
    }

    private func showPermissionHint() {
        let message = NSTextField(wrappingLabelWithString: """
            DeskPad needs permission to record your screen — that is how it shows the virtual screen in this window.

            Open System Settings → Privacy & Security → Screen Recording and switch DeskPad on (if it isn't listed, click + and add it). Then quit and reopen DeskPad.
            """)
        message.alignment = .center
        message.textColor = .black
        let button = NSButton(title: "Open Screen Recording Settings", target: self, action: #selector(openScreenRecordingSettings))
        let stack = NSStackView(views: [message, button])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
        ])
    }

    @objc private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func didClickOnScreen(_ gestureRecognizer: NSGestureRecognizer) {
        guard let screenResolution = previousResolution else {
            return
        }
        let clickedPoint = gestureRecognizer.location(in: view)
        let onScreenPoint = NSPoint(
            x: clickedPoint.x / view.frame.width * screenResolution.width,
            y: (view.frame.height - clickedPoint.y) / view.frame.height * screenResolution.height
        )
        store.dispatch(MouseLocationAction.requestMove(toPoint: onScreenPoint))
    }
}
