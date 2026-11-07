import Carbon
import Cocoa
import ReSwift

struct ShortcutsViewData: ViewDataType {
    typealias StateFragment = ShortcutsState

    static func fragment(of appState: AppState) -> ShortcutsState {
        return appState.shortcutsState
    }

    let shortcuts: ShortcutsState

    init(for fragment: ShortcutsState) {
        shortcuts = fragment
    }
}

// The "Shortcuts…" window: one row per changeable shortcut. Clicking a shortcut's button
// records the next key combination pressed in this window (a local event monitor, so no
// permission is involved); Esc cancels. Invalid combinations are refused with an explanation.
class ShortcutsViewController: SubscriberViewController<ShortcutsViewData> {
    private var shortcuts = ShortcutsState.initialState
    private var recording: ShortcutKind?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    private var recorderButtons: [ShortcutKind: NSButton] = [:]
    private var resetButtons: [ShortcutKind: NSButton] = [:]
    private let messageLabel = NSTextField(wrappingLabelWithString: " ")

    override func loadView() {
        let rows = ShortcutKind.allCases.map(makeRow)

        messageLabel.font = .systemFont(ofSize: 11)
        let note = NSTextField(wrappingLabelWithString: "Shortcuts work system-wide and need no extra permission. Pick a combination other apps don't use.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: rows + [messageLabel, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: 540),
        ])
    }

    private func makeRow(for kind: ShortcutKind) -> NSView {
        let title = NSTextField(labelWithString: kind.title)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let detail = NSTextField(wrappingLabelWithString: kind.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let recorder = NSButton(title: "", target: self, action: #selector(recorderClicked(_:)))
        recorder.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
        recorder.bezelStyle = .rounded
        recorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
        recorderButtons[kind] = recorder

        let reset = NSButton(title: "Reset", target: self, action: #selector(resetClicked(_:)))
        reset.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
        reset.bezelStyle = .rounded
        resetButtons[kind] = reset

        let row = NSStackView(views: [text, recorder, reset])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    override func update(with viewData: ShortcutsViewData) {
        shortcuts = viewData.shortcuts
        refreshButtons()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: view.window, queue: .main
        ) { [weak self] _ in self?.stopRecording() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopRecording()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    private func refreshButtons() {
        for kind in ShortcutKind.allCases {
            recorderButtons[kind]?.title = recording == kind ? "Press shortcut…" : shortcuts[kind].displayString
            resetButtons[kind]?.isEnabled = shortcuts[kind] != kind.defaultShortcut
        }
    }

    private func showMessage(_ text: String, isError: Bool = false) {
        messageLabel.stringValue = text.isEmpty ? " " : text
        messageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func kind(of sender: NSButton) -> ShortcutKind? {
        sender.identifier.flatMap { ShortcutKind(rawValue: $0.rawValue) }
    }

    @objc private func recorderClicked(_ sender: NSButton) {
        guard let kind = kind(of: sender) else { return }
        startRecording(kind)
    }

    @objc private func resetClicked(_ sender: NSButton) {
        guard let kind = kind(of: sender) else { return }
        stopRecording()
        store.dispatch(ShortcutsAction.reset(kind))
        showMessage("Reset to \(kind.defaultShortcut.displayString).")
    }

    private func startRecording(_ kind: ShortcutKind) {
        stopRecording()
        recording = kind
        showMessage("Press the new shortcut, or Esc to cancel.")
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
        refreshButtons()
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if recording != nil {
            recording = nil
            showMessage("")
            refreshButtons()
        }
    }

    // Returns nil to swallow the key while recording.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let kind = recording else { return event }
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return nil
        }
        let shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: Shortcut.carbonModifiers(from: event.modifierFlags))
        switch shortcuts.validate(shortcut, for: kind) {
        case .valid:
            stopRecording()
            store.dispatch(ShortcutsAction.set(kind, shortcut))
            showMessage("Changed to \(shortcut.displayString).")
        case let .rejected(reason):
            showMessage(reason, isError: true)
        }
        return nil
    }
}
