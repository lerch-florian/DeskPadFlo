# DeskPad

A macOS app that creates a virtual display (via the private `CGVirtualDisplay`
API) and mirrors it live inside its own window, so a presenter can drag
windows onto a dedicated, easily shareable "screen" instead of sharing their
whole real desktop.

## Architecture

Unidirectional data flow via [ReSwift](https://github.com/ReSwift/ReSwift)
(Redux-style: one `AppState`, actions, reducers, middleware). All state lives
under `DeskPad/Backend/`, one subfolder per slice:

- `AppState.swift` / `Store.swift` — the root state and the singleton `store`.
- `SideEffectsMiddleware.swift` — registers all side effects; side effects are
  plain closures `(Action, dispatch, getState) -> Void` run on every dispatch.
- `MouseLocation/` — tracks whether the OS cursor is currently on the virtual
  display (`MouseLocationState`), handles the click-to-jump-in gesture
  (`MouseLocationAction.requestMove`, via `CGDisplayMoveCursorToPoint`), and
  the edge-exit warp-back-out behavior (`mouseEdgeExitSideEffect`, via
  `CGWarpMouseCursorPosition`).
- `ScreenConfiguration/` — resolution/scale-factor/displayID of the virtual
  display, updated on `NSApplication.didChangeScreenParametersNotification`
  (fires when the user changes the display's resolution in System Settings).
- `PreviewWindow/` — the DeskPad window's own content frame in global screen
  coordinates, kept in sync so the edge-exit warp knows where to land the
  cursor. Updated from `ScreenViewController`'s `windowDidMove`/
  `windowDidResize` and whenever the resolution-driven layout changes.

`Frontend/Screen/ScreenViewController.swift` is the one view controller: it
creates the `CGVirtualDisplay`, opens a `CGDisplayStream` to pull frames off
it into the window's layer, and drives the click-to-enter /
`NSWindowDelegate` plumbing. `SubscriberViewController<ViewData>` is a small
generic base class that subscribes to a `ViewDataType` slice of `AppState`
and calls `update(with:)` on the main thread — `ScreenViewData` is the one
concrete `ViewDataType` in the app.

`CGVirtualDisplayPrivate.h` is a hand-written header declaring the private
`CGVirtualDisplay*` Objective-C classes that already exist inside the system
`CoreGraphics.framework` — it's not a separate framework, just enough
declarations for Swift to call the private symbols via the bridging header
(`DeskPad-Bridging-Header.h`).

## Building and testing without Xcode.app

This machine may only have the Command Line Tools installed, not the full
Xcode.app (`xcodebuild`/`actool` unavailable — check with `xcode-select -p`).
**You do not need Xcode.app to build or run this app.** Command Line Tools
already ship `swiftc`/`swift build` and the full macOS SDK (Cocoa, AppKit,
CoreGraphics), which is all this project needs — the only "private" piece
(`CGVirtualDisplay`) is a header declaration, not a separate framework.

To compile-check and run without a Xcode project file, symlink the real
sources into a throwaway SwiftPM package (edits to the real files are picked
up on rebuild since it's real symlinks, not copies):

```bash
mkdir -p /tmp/deskpad-cli-build/Sources/DeskPadCLI
cd /tmp/deskpad-cli-build
for f in $(find /Users/florianlerch/ExternProjects/DeskPad/DeskPad -name "*.swift"); do
  ln -sf "$f" "Sources/DeskPadCLI/$(basename "$f")"
done
```

`Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DeskPadCLI",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(url: "https://github.com/ReSwift/ReSwift.git", from: "6.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "DeskPadCLI",
            dependencies: ["ReSwift"],
            swiftSettings: [
                .unsafeFlags([
                    "-import-objc-header",
                    "/Users/florianlerch/ExternProjects/DeskPad/DeskPad/CGVirtualDisplayPrivate.h",
                ]),
            ]
        ),
    ]
)
```

Then `swift build && ./.build/debug/DeskPadCLI`.

Caveats of this route (fine for functional testing, not for shipping):
- No `Assets.xcassets` compiled in (no app icon; `NSColor(named:)` lookups for
  the title-bar highlight silently return `nil` — cosmetic only).
- Runs as a bare unsigned, unsandboxed binary rather than a signed `.app`.
  This is actually convenient here: the `com.apple.security.temporary-
  exception.mach-lookup.global-name` entitlement in
  `DeskPad/DeskPad.entitlements` only matters under App Sandbox, so skipping
  the bundle/signing step sidesteps that entirely.
- macOS will still prompt for **Screen Recording** permission the first time
  `CGDisplayStream` starts (grant it to the built binary, or your terminal,
  in System Settings → Privacy & Security → Screen Recording, then rerun).

For a real, signed, distributable build (asset catalog, entitlements,
`.app` bundle, notarization), a full Xcode.app install and
`DeskPad.xcodeproj` are required — there's no way around that for release
builds.

There is no unit test target in this project; verification is manual/visual
(run the app, click into the virtual display, exercise the behavior).

## Conventions

- New state slices follow the existing pattern exactly: one `Action` enum,
  one `Equatable` state struct with `static var initialState`, one pure
  reducer function, wired into `AppState`/`appReducer`. Side effects that
  touch the OS (timers, `CGEventTap`-style polling, notifications) live next
  to the state they update and get registered in `SideEffectsMiddleware`.
- Coordinate systems: `NSScreen`/`NSEvent.mouseLocation`/`NSWindow.frame` all
  use AppKit's bottom-left-origin global coordinate space, consistent across
  every screen (including the virtual one, once it exists as an `NSScreen`).
  `CGWarpMouseCursorPosition`/`CGDisplayBounds` use Quartz's top-left-origin
  space instead — flip `y` via `mainScreenHeight - y` when converting between
  them (see `mouseEdgeExitSideEffect` for the reference conversion).
