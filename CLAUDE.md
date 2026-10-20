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
  the two-way edge-crossing behavior (`mouseEdgeCrossingSideEffect`): warping
  the cursor out of the virtual display onto the mirrored point in the
  preview window, and/or into the virtual display when the cursor reaches the
  preview window (via `CGWarpMouseCursorPosition`). Each direction is
  independently toggled by `MouseEdgeBehaviorState` (see below) and can be
  turned on/off from the "Options" menu.
  - Exit fires whenever the cursor, while on the virtual display, is within a
    small margin of its edge — this is reliable even for fast movement
    because the OS clamps cursor motion at a real display's own bounds when
    there's no arranged neighbor beyond it, so the cursor lingers right at
    the edge across several polling ticks.
  - Exit also fires on an on→off *transition*: when the virtual display is
    arranged next to a real one, a fast movement carries the cursor across the
    shared edge and far onto the real display within one tick
    (`crossingExitTarget` intersects the segment from the last on-display
    position to the current one with the display's bounds to find the real
    crossing point). After any exit-warp `lastVirtualLocation` is cleared,
    otherwise the next tick sees the warp itself as a second exit and re-warps
    to the wrong edge. On-display checks must use a closed interval: the
    cursor clamped at the top/right edge reports exactly `maxY`/`maxX`, which
    `CGRect.contains` (half-open) treats as outside. In a corner the nearest
    edge wins.
  - Entry only counts if the preview window is the topmost window under the
    cursor (`isPreviewWindowVisible`, via `CGWindowListCopyWindowInfo`, only
    evaluated on a potential entry — it's too slow to run at 60Hz).
  - Entry fires on a genuine outside→inside transition into the preview
    window's content frame (tracked tick-to-tick), *not* proximity to its
    edge — nothing clamps cursor motion at an ordinary window's boundary, so
    a fast mouse movement can jump from clearly outside to clearly inside
    between two polling ticks, skipping over any thin edge-margin band
    entirely. This was a real bug (jump-in only worked when moving the mouse
    slowly) fixed by switching from margin-based to transition-based
    detection.
  - Both directions run on one 60Hz timer with one-shot suppression flags
    (`skipExitCheckOnce`/`skipEntryCheckOnce`): an exit-warp lands the cursor
    just inside the window's edge, which would otherwise immediately satisfy
    entry's trigger condition (and vice versa for entry landing near the
    virtual display's edge), causing an infinite back-and-forth when both
    directions are enabled at once. Since an entry lands right at the display
    edge (still inside the exit margin on the next tick), `exitArmed` also
    keeps exit disabled after an entry until the cursor is `exitRearmDistance`
    clear of every edge.
  - Every jump is a cursor warp, and macOS freezes hardware mouse input for
    0.25s after one by default; the cursor visibly stuck. Fixed by setting
    `localEventsSuppressionInterval = 0` on a retained `CGEventSource`.
- `MouseEdgeBehavior/` — two independent booleans, `jumpOutEnabled` (default
  `true`, preserves original behavior) and `jumpInEnabled` (default `false`,
  since it's new — click-to-enter always works regardless of this toggle).
- `ScreenConfiguration/` — resolution/scale-factor/displayID of the virtual
  display. `AvailableResolutions.swift` is the single source of truth for
  the preset resolution list, shared between the modes declared to
  `CGVirtualDisplay` (`ScreenViewController`) and the "Resolution" menu
  (`AppDelegate`). `ScreenConfigurationSideEffect.swift` has two paths:
  - Passive: updated on `NSApplication.didChangeScreenParametersNotification`
    (fires when the user changes the display's resolution via System
    Settings, or after this app switches it programmatically).
  - Active: `switchDisplayMode(displayID:targetLogicalSize:)` — given a
    logical (point) size, finds the matching `CGDisplayMode` among
    `CGDisplayCopyAllDisplayModes(display, [kCGDisplayShowDuplicateLowResolutionModes: true])`
    (that option is required — scaled/"looks like" modes are omitted by
    default) and switches to it via `CGBeginDisplayConfiguration` /
    `CGConfigureDisplayWithDisplayMode` / `CGCompleteDisplayConfiguration`.
    When both a native (1x) and HiDPI-scaled (2x) mode exist for the same
    logical size (they share the same declared `CGVirtualDisplayMode` pixel
    value but differ in scale), it picks the one with the larger
    `pixelWidth`, i.e. prefers the crisp Retina variant. Used by: matching
    the built-in display's resolution once on first launch
    (`applyBuiltInResolutionIfNeeded`), and the "Resolution" menu's
    `ScreenConfigurationAction.selectResolution`. Dispatches the *known*
    target resolution immediately after a successful switch rather than
    waiting for a follow-up `didChangeScreenParametersNotification` — that
    notification is not reliable enough to depend on (this was a real bug:
    the display's mode switched correctly at the system level, confirmed via
    `CGDisplayCopyDisplayMode`, but the app's window never resized because
    it was waiting on a notification that never came).
- `PreviewWindow/` — the DeskPad window's own content frame in global screen
  coordinates, kept in sync so the edge-crossing warps know where to land the
  cursor. Updated from `ScreenViewController`'s `windowDidMove`/
  `windowDidResize` and whenever the resolution-driven layout changes.

`Frontend/Screen/ScreenViewController.swift` is the one view controller: it
creates the `CGVirtualDisplay` (declaring modes from `availableResolutions`,
plus the built-in display's logical size if not already in that list — the
mode must be declared using the *logical/point* size, not the pixel size;
`CGVirtualDisplay` automatically generates a corresponding HiDPI (2x-pixel)
companion mode for each declared size when it fits under
`maxPixelsWide`/`maxPixelsHigh`, which is what actually gets selected to
match a Retina-scaled built-in resolution), opens a `CGDisplayStream` to pull
frames off it into the window's layer, and drives the click-to-enter /
`NSWindowDelegate` plumbing. On first launch it sizes the window to fit
within a quarter of the screen's visible area (`quarterScreenSize(fitting:)`,
preserving the resolution's aspect ratio) rather than the resolution's full
point size; later resolution changes still resize to the exact resolution.
`SubscriberViewController<ViewData>` is a small generic base class that
subscribes to a `ViewDataType` slice of `AppState` and calls `update(with:)`
on the main thread — `ScreenViewData` is the one concrete `ViewDataType` in
the app.

`AppDelegate.swift` builds the menu bar: besides the app menu (Quit), a
"Resolution" menu (all `availableResolutions` entries plus a dynamic "Match
Built-in Display" entry, each dispatching
`ScreenConfigurationAction.selectResolution`) and an "Options" menu (the two
`MouseEdgeBehaviorAction` toggles, checkmarks refreshed via
`NSMenuDelegate.menuNeedsUpdate` rather than a full ReSwift subscription).

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

### Compiling via a throwaway SwiftPM package

Symlink the real sources into a SwiftPM package (edits to the real files are
picked up on rebuild since it's real symlinks, not copies):

```bash
mkdir -p ~/deskpad-cli-build/Sources/DeskPadCLI
cd ~/deskpad-cli-build
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

Then `swift build`. New source files need their own `ln -sf` into
`Sources/DeskPadCLI/` before the next build picks them up.

### Packaging into a real, launchable `.app` (recommended over running the raw binary)

Running the compiled binary directly (`./.build/debug/DeskPadCLI`) works for
a quick compile-check, but it's launched outside Launch Services: no proper
menu bar/frontmost activation (`NSApp.activate(ignoringOtherApps:)` gets
silently denied for a process launched this way), no Dock icon. Wrapping it
in a minimal `.app` bundle fixes this and costs little:

```bash
mkdir -p ~/DeskPad.app/Contents/MacOS
cp ~/deskpad-cli-build/.build/debug/DeskPadCLI ~/DeskPad.app/Contents/MacOS/DeskPad
```

`~/DeskPad.app/Contents/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>DeskPad</string>
	<key>CFBundleIdentifier</key><string>com.deskpad.dev-test</string>
	<key>CFBundleName</key><string>DeskPad</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
```

Sign and register it, then launch via `open` (same path Finder uses):

```bash
codesign --force --deep --sign "DeskPad Dev Signing" ~/DeskPad.app   # see identity note below
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/DeskPad.app
open ~/DeskPad.app
```

**Use a stable signing identity, not ad-hoc (`--sign -`).** Ad-hoc signing
derives the code identity from the binary's own content hash, so *every
rebuild produces a different identity* — macOS TCC (Screen Recording
permission) then treats each rebuild as a brand-new, unrecognized app,
producing duplicate entries in System Settings and an endless
re-grant-permission loop on every code change. Fix: create one self-signed
local code-signing certificate once and reuse it for every rebuild —
`security find-identity -v -p codesigning` may still report "0 valid
identities" for a plain self-signed cert (it fails full trust-policy
evaluation), but `codesign --sign "<name>"` can still find and use it
directly by name; that's sufficient. If TCC state is already a mess from
prior ad-hoc-signed rebuilds, clear it first:
`tccutil reset ScreenCapture com.deskpad.dev-test`. Creating the certificate
itself (openssl → `.p12` → import into keychain) needs either the person's
explicit one-time GUI interaction (double-click the `.p12`, enter its export
password, confirm the login keychain unlock) or their explicit approval to
run `security import` — writing to the login keychain is a persistent
system change the harness will not do silently.

Caveats of this whole approach (fine for functional testing, not for
shipping):
- No `Assets.xcassets` compiled in (no real app icon; `NSColor(named:)`
  lookups for the title-bar highlight silently return `nil` — cosmetic
  only).
- Not sandboxed. This is actually convenient here: the `com.apple.security.
  temporary-exception.mach-lookup.global-name` entitlement in
  `DeskPad/DeskPad.entitlements` only matters under App Sandbox, so skipping
  entitlements entirely sidesteps that.
- macOS still prompts for **Screen Recording** permission the first time
  `CGDisplayStream` starts (System Settings → Privacy & Security → Screen
  Recording → enable it, then relaunch once).

For a real, distributable, notarized build (asset catalog, entitlements,
sandboxing, a real Developer ID), a full Xcode.app install and
`DeskPad.xcodeproj` are required — there's no way around that for release
builds.

There is no unit test target in this project; verification is manual —
either visually (ask the person to check), or headlessly via `osascript`
driving System Events (menu bar items/clicks, window position/size) and
small standalone Swift probe scripts calling `CoreGraphics`/`CGDisplay*`
APIs directly (e.g. `CGGetActiveDisplayList` + `CGDisplayBounds` /
`CGDisplayCopyDisplayMode` to check a display's actual state,
`CGWarpMouseCursorPosition` + `CGEventCreate(nil)!.location` to simulate
cursor movement and confirm where it ends up) — this caught real bugs (see
architecture notes above) that a build-only check would have missed.

## Conventions

- New state slices follow the existing pattern exactly: one `Action` enum,
  one `Equatable` state struct with `static var initialState`, one pure
  reducer function, wired into `AppState`/`appReducer`. Side effects that
  touch the OS (timers, polling, notifications) live next to the state they
  update and get registered in `SideEffectsMiddleware`.
- Coordinate systems: `NSScreen`/`NSEvent.mouseLocation`/`NSWindow.frame` all
  use AppKit's bottom-left-origin global coordinate space, consistent across
  every screen (including the virtual one, once it exists as an `NSScreen`).
  `CGWarpMouseCursorPosition`/`CGDisplayBounds` use Quartz's top-left-origin
  space instead — flip `y` via `mainScreenHeight - y` when converting between
  them (see `warpCursor` in `MouseLocationSideEffect.swift`).
- When polling cursor position to detect a boundary crossing, prefer
  transition detection (previous tick vs. current tick) over proximity/margin
  checks unless the OS itself clamps motion at that boundary (a display's own
  edge does; an arbitrary window's edge does not) — a margin band can be
  skipped over entirely between two polling ticks by a fast enough movement.
