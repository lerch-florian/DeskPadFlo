import Cocoa
import ReSwift

enum AppDelegateAction: Action {
    case didFinishLaunching
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

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

        store.dispatch(AppDelegateAction.didFinishLaunching)
    }

    private func makeResolutionMenu() -> NSMenu {
        let menu = NSMenu(title: "Resolution")
        for resolution in availableResolutions {
            menu.addItem(resolutionMenuItem(title: resolution.label, size: resolution.size))
        }
        if let builtInSize = NSScreen.builtIn?.frame.size {
            menu.addItem(.separator())
            menu.addItem(resolutionMenuItem(
                title: "Match Built-in Display (\(Int(builtInSize.width)) × \(Int(builtInSize.height)))",
                size: builtInSize
            ))
        }
        return menu
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

        let jumpOutItem = NSMenuItem(title: "Jump Cursor Out at Screen Edge", action: #selector(toggleJumpOut(_:)), keyEquivalent: "")
        jumpOutItem.target = self
        menu.addItem(jumpOutItem)

        let jumpInItem = NSMenuItem(title: "Jump Cursor In at Window Edge", action: #selector(toggleJumpIn(_:)), keyEquivalent: "")
        jumpInItem.target = self
        menu.addItem(jumpInItem)

        return menu
    }

    @objc private func toggleJumpOut(_: NSMenuItem) {
        store.dispatch(MouseEdgeBehaviorAction.setJumpOutEnabled(!store.state.mouseEdgeBehaviorState.jumpOutEnabled))
    }

    @objc private func toggleJumpIn(_: NSMenuItem) {
        store.dispatch(MouseEdgeBehaviorAction.setJumpInEnabled(!store.state.mouseEdgeBehaviorState.jumpInEnabled))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        return true
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Options", menu.items.count == 2 else { return }
        let behavior = store.state.mouseEdgeBehaviorState
        menu.items[0].state = behavior.jumpOutEnabled ? .on : .off
        menu.items[1].state = behavior.jumpInEnabled ? .on : .off
    }
}
