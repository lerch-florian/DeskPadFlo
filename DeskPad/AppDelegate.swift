import Cocoa
import ReSwift

enum AppDelegateAction: Action {
    case didFinishLaunching
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    private var clickMonitor: Any?

    func applicationDidFinishLaunching(_: Notification) {
        let viewController = ScreenViewController()
        window = NSWindow(contentViewController: viewController)
        window.delegate = viewController
        window.title = "DeskPad"
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.titleVisibility = .hidden
        window.backgroundColor = .white
        window.contentMinSize = CGSize(width: 400, height: 300)
        window.contentMaxSize = CGSize(width: 5120, height: 2160)
        window.styleMask.insert(.resizable)
        window.collectionBehavior.insert(.fullScreenNone)

        let mainMenu = NSMenu()
        let mainMenuItem = NSMenuItem()
        let subMenu = NSMenu(title: "MainMenu")
        let quitMenuItem = NSMenuItem(
            title: "Quit",
            action: #selector(NSApp.terminate),
            keyEquivalent: "q"
        )
        subMenu.addItem(quitMenuItem)
        mainMenuItem.submenu = subMenu

        let resolutionMenuItem = NSMenuItem()
        resolutionMenuItem.title = "Resolution"
        resolutionMenuItem.submenu = makeResolutionMenu()

        let optionsMenuItem = NSMenuItem()
        optionsMenuItem.title = "Options"
        optionsMenuItem.submenu = makeOptionsMenu()

        mainMenu.items = [mainMenuItem, resolutionMenuItem, optionsMenuItem]
        NSApplication.shared.mainMenu = mainMenu

        registerEmergencyHotKey()
        installRaiseOnVirtualClickMonitor()
        store.dispatch(AppDelegateAction.didFinishLaunching)
    }

    // Clicks on the virtual display land in other apps' windows, so DeskPad only sees
    // them through a global monitor (mouse events need no extra permission). Bring the
    // preview window forward on such a click, without activating DeskPad, so the click's
    // target keeps keyboard focus.
    private func installRaiseOnVirtualClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard
                store.state.mouseEdgeBehaviorState.cursorMode.raisesWindowOnVirtualClick,
                let displayID = store.state.screenConfigurationState.displayID,
                let virtualScreen = NSScreen.screens.first(where: { $0.displayID == displayID }),
                NSMouseInRect(NSEvent.mouseLocation, virtualScreen.frame, false)
            else { return }
            self?.window.orderFrontRegardless()
        }
    }

    private func makeResolutionMenu() -> NSMenu {
        let menu = NSMenu(title: "Resolution")
        for resolution in availableResolutions {
            menu.addItem(resolutionMenuItem(title: resolution.label, size: resolution.size))
        }
        if let builtInSize = NSScreen.builtIn?.frame.size {
            menu.addItem(.separator())

            let quarter = CGSize(width: (builtInSize.width / 2).rounded(.down), height: (builtInSize.height / 2).rounded(.down))
            let defaultItem = NSMenuItem(
                title: "Quarter of Built-in Display, default (\(Int(quarter.width)) × \(Int(quarter.height)))",
                action: #selector(selectDefaultResolution(_:)),
                keyEquivalent: ""
            )
            defaultItem.target = self
            menu.addItem(defaultItem)

            menu.addItem(resolutionMenuItem(
                title: "Match Built-in Display (\(Int(builtInSize.width)) × \(Int(builtInSize.height)))",
                size: builtInSize
            ))
        }
        return menu
    }

    @objc private func selectDefaultResolution(_: NSMenuItem) {
        store.dispatch(ScreenConfigurationAction.selectDefaultResolution)
    }

    private func resolutionMenuItem(title: String, size: CGSize) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectResolution(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = NSValue(size: size)
        return item
    }

    @objc private func selectResolution(_ sender: NSMenuItem) {
        guard let size = (sender.representedObject as? NSValue)?.sizeValue else { return }
        store.dispatch(ScreenConfigurationAction.selectResolution(size))
    }

    private func makeOptionsMenu() -> NSMenu {
        let menu = NSMenu(title: "Options")
        menu.delegate = self

        let header = NSMenuItem(title: "Cursor Mode", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for mode in CursorMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectCursorMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.toolTip = mode.summary
            item.indentationLevel = 1
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let blockItem = NSMenuItem(title: "Disconnect Screen from OS Arrangement", action: #selector(toggleBlockOSScreenConnection(_:)), keyEquivalent: "")
        blockItem.target = self
        blockItem.toolTip = "Arranges the virtual screen so it touches the real screens only at a corner, so macOS can't "
            + "carry the cursor between them. Only the selected mode's own jumps move the cursor across."
        menu.addItem(blockItem)

        menu.addItem(.separator())

        // The same shortcut is registered system-wide in registerEmergencyHotKey().
        let emergencyItem = NSMenuItem(title: "Emergency: Move Cursor to Main Screen", action: #selector(emergencyCursorReset(_:)), keyEquivalent: "h")
        emergencyItem.keyEquivalentModifierMask = [.command, .option, .shift]
        emergencyItem.target = self
        menu.addItem(emergencyItem)

        return menu
    }

    @objc private func selectCursorMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? CursorMode else { return }
        store.dispatch(MouseEdgeBehaviorAction.setCursorMode(mode))
    }

    @objc private func toggleBlockOSScreenConnection(_: NSMenuItem) {
        store.dispatch(MouseEdgeBehaviorAction.setBlockOSScreenConnection(!store.state.mouseEdgeBehaviorState.blockOSScreenConnection))
    }

    @objc private func emergencyCursorReset(_: NSMenuItem) {
        jumpCursorToMainScreenCenter()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        return true
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Options" else { return }
        let behavior = store.state.mouseEdgeBehaviorState
        for item in menu.items {
            if let mode = item.representedObject as? CursorMode {
                item.state = mode == behavior.cursorMode ? .on : .off
            } else if item.action == #selector(toggleBlockOSScreenConnection(_:)) {
                item.state = behavior.blockOSScreenConnection ? .on : .off
            }
        }
    }
}
