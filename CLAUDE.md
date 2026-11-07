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
  preview window, and into the virtual display when the cursor moves onto the
  preview window (via `CGWarpMouseCursorPosition`). What it does is derived
  from the selected `CursorMode` in `MouseEdgeBehaviorState` (see below),
  chosen in the "Options" menu.
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
  - Entry only counts if the preview window *itself* is the topmost window under the
    cursor (`isPreviewWindowVisible`, compared by window number — comparing the owning
    process would let the app's own Shortcuts window, which covers the preview like any
    other window, count as the preview and the cursor would jump into it; the Dock's
    screen-sized transparent overlay is ignored for the same reason: while it exists,
    nothing could enter), via `CGWindowListCopyWindowInfo`, only
    evaluated on a potential entry — it's too slow to run at 60Hz). Modes
    that don't enter automatically skip the check entirely.
  - Seamless mode additionally leaves *where the virtual screen isn't
    visible*: while on the virtual display the cursor is drawn inside the
    preview window at the point its position maps to, and when another window
    covers that point `coveredExitTarget` warps the real cursor to exactly that
    point (onto the covering window) — no visible movement. This runs every
    tick, so it reads a cached window list (`frontToBackWindows`, max age
    `coveredCheckWindowListMaxAge` = 0.1s) instead of querying afresh.
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
- `MouseEdgeBehavior/` — `cursorMode` (a `CursorMode`, default `.auto`) and
  `blockOSScreenConnection` (default `true`). Both are persisted in `UserDefaults`
  (`initialState` reads them, `mouseEdgeBehaviorPersistenceSideEffect` writes them on every
  `MouseEdgeBehaviorAction`; unknown stored values fall back to the defaults). Every mode leaves at the virtual
  display's borders; the modes differ in what the `CursorMode` properties say:
  - `seamless`: enters automatically onto any visible part of the preview
    window, also leaves where the mapped point is covered
    (`exitsWhereCovered`), never raises the preview window (`raisesWindowOnEntry`
    and `raisesWindowOnVirtualClick` are false, so the click monitor in
    `AppDelegate` is also off).
  - `auto`: enters automatically, raises the preview window on entry (the
    entry branch calls `AppDelegate.window.orderFrontRegardless()`), and on a
    click on the virtual display.
  - `clickToEnter`: no automatic entry (`entersAutomatically` false); only the
    click gesture in `ScreenViewController` enters.
  `blockOSScreenConnection` ("Disconnect Screen from OS Arrangement") removes the OS's
  own connection between the virtual display and the real ones, via the display
  *arrangement* (`arrangeVirtualDisplay` in `ScreenConfigurationSideEffect.swift`):
  `CGConfigureDisplayOrigin` does work on the virtual display. Findings: macOS snaps any
  *gap* shut (it won't keep displays apart), but accepts a position where the virtual
  display touches the real ones **only at a corner** (`cornerOnlyOrigin`, bottom-right
  of the arrangement preferred), which leaves no shared edge for the cursor to cross.
  Off puts it back beside the main display (macOS' default). The arrangement is
  re-applied on every `didChangeScreenParametersNotification` (display appears, resolution
  change) and when the option is toggled; it's a no-op when already in place. Everything
  else is arrangement-independent (all geometry comes from `NSScreen` frames), so with the
  display at the bottom-right every edge is a clamped, unneighbored edge for the exit.
  The older software hold (undoing an OS crossing that isn't one of our own warps) stays
  active while the option is on, as a safety net: a path through exactly the corner pixel
  might still slip across, and scripted events can't tell (see testing notes — synthetic
  absolute positions bypass the window server's edge clamping, so the OS's own clamping
  can't be measured headlessly; only the arrangement read-back via `CGDisplayBounds` can).
  Any entry (`requestMove`) disarms exit until the cursor is clear of the edge, whether
  it came from an auto jump or a click.
  Window handling is described next.
- `MouseLocation/WindowDrag.swift` — window list + drag tracking. Windows are moved
  *by the OS's own drag*, not by us: the window server keeps dragging the grabbed
  window by the cursor's position, so a cursor warp while the button is held carries
  it along (no Accessibility permission needed). What's needed around that:
  - `WindowDragTracker` finds the window grabbed at mouse-down (rising edge of
    `NSEvent.pressedMouseButtons`, polled in the 60Hz tick) and calls it *dragged*
    once its bounds origin has moved. `isPreviewWindowVisible` ignores the dragged
    window; otherwise it always covers the preview and nothing could be dragged in.
  - After every warp with the left button down, `nudgeDrag` posts a
    `leftMouseDragged` event at the destination, so the window follows at once rather
    than on the next hardware movement (verified: without further events the window
    is already on the other screen).
  - On an exit while a window is being dragged, the preview is ordered *below* that
    window (`order(.below, relativeTo:)` works across processes). Entering and clicking
    raise the preview, so without this the dragged window lands behind it with its
    title bar under the preview, and the next grab drags the preview instead.
  - Click to Enter only: dragging a window over the visible preview enters on a shake
    (`ShakeDetector`: ≥3 direction reversals of ≥35pt within 0.8s) or on cmd+shift+D.
    cmd+shift+D is a common shortcut elsewhere, so it is registered system-wide only
    while a foreign-window drag is held in this mode (`setDragEntryHotKeyRegistered`,
    toggled each tick) and unregistered otherwise. The single Carbon hotkey handler
    dispatches on `EventHotKeyID` (emergency reset vs. drag entry).
  - Dragging the preview window *itself* (mouse-down on it, `isHoldingOwnWindow`) must
    not take part in any jump: the window moves under the cursor, so an entry (the stored
    window frame lags the real one by a few ticks, so the cursor briefly counts as
    "over the preview") carries it into the virtual display, and the guard below then
    threw it back — it ended up bouncing between the screen corners. While held, the
    tick returns early (`holdPreviewDragOnRealDisplays`) and, if the cursor crossed onto
    the virtual display, warps it back to its last real position.
  - `ScreenViewController.keepWindowOffVirtualDisplay`: the preview window's centre is
    never allowed onto the virtual display (it would be invisible there). It is clamped
    to the real displays' edge on `windowDidMove` — a soft wall, not a snap back inside,
    which showed as a visible jump.
- `Shortcuts/` — the two user-changeable global shortcuts (`ShortcutKind`: emergency reset, drag
  entry; defaults ⌘⌥⇧H and ⌘⇧D). A `Shortcut` is a key code plus Carbon modifier flags, the form
  `RegisterEventHotKey` takes. State is persisted in `UserDefaults` (only non-default values);
  `shortcutsSideEffect` saves on every `ShortcutsAction` and re-registers the emergency hotkey
  (`updateEmergencyHotKey`). The drag hotkey is only registered during a foreign-window drag in
  Click to Enter mode; `setDragEntryHotKeyRegistered` is called every tick with the current shortcut
  and re-registers if it changed. `ShortcutsState.validate` refuses a combination with no ⌘/⌃/⌥
  (unless it is an F-key; it would swallow typing system-wide), macOS-reserved ones (⌘Q, ⌘W, ⌘H, ⌘M,
  ⌘Tab, ⌘Space, ⌘`, ⌘⌥Esc) and one already used by the other shortcut. Display names come from
  `UCKeyTranslate` for the current keyboard layout, plus a table for non-printing keys. The
  "Shortcuts…" window (`Frontend/Shortcuts/ShortcutsViewController.swift`) records the next key
  combination with a *local* event monitor (only while that window is key; no permission needed;
  it returns nil to swallow the key, so even ⌘Q is caught while recording) and stops recording
  on Esc, on the window losing focus or closing. The Options menu's emergency item shows the
  current shortcut as its key equivalent when the key can be expressed as one (refreshed whenever
  the menu opens). Carbon only reports a hotkey clash with *this* app, so a combination another app
  has already taken can't be detected.
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
    `pixelWidth`, i.e. prefers the crisp Retina variant. Used by: the default
    resolution once on first launch (`applyDefaultResolutionIfNeeded`), and
    the "Resolution" menu's `ScreenConfigurationAction.selectResolution`.
    The default is a quarter of the host (built-in) screen — half its width and
    half its height, e.g. 840×525 for 1680×1050 — so it shows nearly 1:1 in the
    preview window, which also opens at about a quarter of the screen. That
    half-size mode exists because every declared `CGVirtualDisplayMode` (w×h)
    yields three modes: native w×h, HiDPI w×h (pixels 2w×2h) and HiDPI
    w/2×h/2 (pixels w×h); declaring the host's own size (done in
    `ScreenViewController`) therefore provides the sharp quarter-size one. If the
    host size doesn't halve into an available mode it falls back to matching the
    host exactly.
    The resolution is persisted as an *explicit choice only* (`StoredResolution`, two
    `UserDefaults` doubles): a menu selection stores it, the menu's "Quarter of Built-in
    Display, default" entry (`ScreenConfigurationAction.selectDefaultResolution`) clears it.
    Storing whatever is active instead would freeze the default at one host size. On launch
    `applyInitialResolution` applies the stored size if this display still offers it and
    otherwise falls back to the default. Dispatches the *known*
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
`ScreenConfigurationAction.selectResolution`) and an "Options" menu (the three
`CursorMode`s with their summaries as tooltips, plus the "Disconnect Screen
from OS Arrangement" toggle and the emergency cursor reset; checkmarks refreshed via
`NSMenuDelegate.menuNeedsUpdate` rather than a full ReSwift subscription).

`CGVirtualDisplayPrivate.h` is a hand-written header declaring the private
`CGVirtualDisplay*` Objective-C classes that already exist inside the system
`CoreGraphics.framework` — it's not a separate framework, just enough
declarations for Swift to call the private symbols via the bridging header
(`DeskPad-Bridging-Header.h`).

## Building, signing and distributing (no Xcode.app, no paid Apple account)

Only the Command Line Tools are needed (`xcode-select --install`; check with
`xcode-select -p`): `swift build` and the macOS SDK cover everything, and the one
"private" piece (`CGVirtualDisplay`) is just a header, not a framework. The repo has a
root `Package.swift` (target `DeskPad`, source folder `DeskPad/`, the bridging header
passed via `-import-objc-header`), so `swift build` works straight from a clone.

The goal is that others can use the app with little effort **without anyone paying
for an Apple Developer account**, which rules out Developer ID signing and
notarization. Everything below follows from that.

### Scripts (`scripts/`)

- `build-dev.sh` — debug build, refreshes `~/DeskPad.app` in place, signs it with the stable
  identity (`SIGN_IDENTITY`, default `DeskPad Dev Signing`) and relaunches it.
- `assemble-app.sh <binary> <out.app> <version>` — wraps a built binary into a bundle:
  `Info.plist` from `Info.plist.in`, and the icon generated from the PNGs in
  `Assets.xcassets` with `iconutil` (ships with macOS). That is why the asset catalog
  isn't needed at all: the title-bar colours are plain system colours in code
  (`selectedContentBackgroundColor` / `windowBackgroundColor`; with `NSColor(named:)` they
  silently came out `nil` in builds without a compiled catalog).
- `package-release.sh [version]` — universal (arm64 + x86_64) `dist/DeskPad.app` and
  `dist/DeskPad.zip`. SwiftPM's `--arch a --arch b` needs Xcode's build engine (`xcbuild`),
  so it builds each architecture with `--triple` and merges with `lipo`. Signs with
  the release certificate when available (ad-hoc otherwise, with a warning; see Signing) and the project's entitlements.
- `install.sh` — the end-user installer (see below).

Bundle ID is `io.github.lerch-florian.DeskPad` (not upstream's `com.stengo.DeskPad`, so the
two apps' permissions can't collide); it is set in `assemble-app.sh`, the scripts and the Xcode project.
Changing it makes macOS ask for the Screen Recording permission again once.

### Signing: stable certificate vs ad-hoc

TCC (Screen Recording) remembers an app by its *designated requirement*. Ad-hoc signing makes
that the binary's content hash, so every rebuild/release looks like a brand-new app: duplicate
entries in System Settings and a re-grant after every update. Signing every build with the same
self-signed certificate makes it `identifier "…" and certificate leaf = H"…"`, which is stable
across builds — and that holds on end users' machines too, they don't need to trust the
certificate. (Verified: after several rebuilds with the certificate the permission, once granted,
never needed granting again.)

**The release identity — never change it casually.** Every release, and the maintainer's dev
builds, must carry exactly this:

| | |
| --- | --- |
| Bundle ID | `io.github.lerch-florian.DeskPad` |
| Certificate | `DeskPad Dev Signing` (self-signed, code-signing EKU, RSA 2048, valid 2026-09-18 to 2036-09-15) |
| Leaf SHA-1 | `dcf636eacacdd33031da32ad1ac66024bd9a9f5e` (public; not a secret) |
| Expected requirement | `identifier "io.github.lerch-florian.DeskPad" and certificate leaf = H"dcf636eacacdd33031da32ad1ac66024bd9a9f5e"` |

`scripts/package-release.sh` enforces this. It uses the certificate automatically when it is in the
keychain, checks the signed app's requirement against the pinned fingerprint (`RELEASE_CERT_HASH`
in the script) and **aborts on a mismatch**; it prints "AD-HOC … do NOT publish" when it had to
fall back to ad-hoc signing (contributors without the certificate). Before `gh release create`,
the "Signed as:" line must say "release identity … OK to publish". Replacing the certificate
on purpose needs `ALLOW_NEW_IDENTITY=1` and a new pinned fingerprint, and costs every user one
re-grant (say so in the release notes). Check any built app by hand with
`codesign -dr - <app>`.

What can change the identity unintentionally, and so makes macOS ask again: a different bundle
ID, a different (or lost) certificate, an ad-hoc build, or a build someone made themselves
(that is a different identity from the downloaded release and gets its own entry).

**Keep the certificate safe.** Its private key lives only in the maintainer's login keychain. It
should be exported once (Keychain Access → "DeskPad Dev Signing" → export as `.p12` with the
maintainer's own password) and stored in a safe place; without it a new Mac, or a wiped keychain,
means a new identity. The `.p12` created during setup sat in a temporary scratch folder with a
throwaway password and must not be relied upon.

**How it was created** (for a rebuild after loss, which means a new pinned fingerprint): an
`openssl req -x509 -newkey rsa:2048 -nodes -days 3650` with a config of `CN = DeskPad Dev Signing`,
`basicConstraints = critical,CA:false`, `keyUsage = critical,digitalSignature`,
`extendedKeyUsage = critical,codeSigning`; then `openssl pkcs12 -export` and a keychain import
(`security import … -T /usr/bin/codesign`, or a double-click on the `.p12`: the `.p12`'s *export*
password is what Keychain Access asks for first, not the Mac password). Writing to the login
keychain needs the person's own go-ahead. `security find-identity -v -p codesigning` reports 0
valid identities for such a certificate (it fails trust evaluation), but `codesign --sign "<name>"`
still finds and uses it by name. Other apps' stale TCC entries:
`tccutil reset ScreenCapture io.github.lerch-florian.DeskPad` resets this app's.

### Gatekeeper and how users get the app

Without notarization Gatekeeper rejects the app (`spctl --assess` says "rejected"), but it only
checks files with the **quarantine** flag, which browsers attach to downloads and `curl` doesn't.
So `install.sh` (`curl -fsSL …/scripts/install.sh | bash`) downloads
`releases/latest/download/DeskPad.zip` with `curl`, verifies the signature, installs to
`/Applications` (falls back to `~/Applications`, never needs sudo), clears the flag and opens it.
A browser-downloaded copy instead needs *System Settings → Privacy & Security → Open Anyway* or
`xattr -dr com.apple.quarantine /Applications/DeskPad.app`. The installer can be tested without
the network: `DESKPAD_ZIP_URL=file://… DESKPAD_APPS_DIR=/tmp/x DESKPAD_NO_OPEN=1 scripts/install.sh`.
Publishing a release = `scripts/package-release.sh <version>` with the certificate, then
`gh release create v<version> dist/DeskPad.zip` (the installer relies on the fixed asset name
`DeskPad.zip`).

### Sandbox

The project's entitlements (App Sandbox + the `com.apple.VirtualDisplay` Mach-service exception
+ read-only user-selected files) are used for dev and release builds alike. Verified: with them
the display, arrangement, resolution switching, cursor jumps, window-list visibility checks,
posted drag events, shake and the Carbon hotkeys all work. (No hardened runtime: that is for
notarization.)

### Xcode project

`DeskPad.xcodeproj` is kept in step *by hand* (new files, groups, bundle ID) and validated only
structurally: it parses, no duplicate or dangling IDs, every Swift file is in the compile phase.
It has **not** been built in Xcode (none was available). It still carries upstream's
`DEVELOPMENT_TEAM`, so contributors choose their own team (a free Apple ID works) or "Sign to
Run Locally". The SwiftPM path is the one that's actually exercised.

### Quirks worth knowing

- A process started as a bare binary (not via `open`/Launch Services) gets no menu bar and
  `NSApp.activate` is silently denied; always test the `.app`.
- macOS does not ask for Screen Recording by itself when `CGDisplayStream` starts: without the
  permission the stream just delivers nothing (blank window) and the app never appears in the
  Screen Recording list. `ScreenViewController.viewDidLoad` therefore checks
  `CGPreflightScreenCaptureAccess()`, calls `CGRequestScreenCaptureAccess()` (system prompt, lists
  the app) and shows an explanation with a button to the right Settings pane in the window.
  A relaunch is needed after granting.

There is no unit test target in this project; verification is manual —
either visually (ask the person to check), or headlessly via `osascript`
driving System Events (menu bar items/clicks, window position/size) and
small standalone Swift probe scripts calling `CoreGraphics`/`CGDisplay*`
APIs directly (e.g. `CGGetActiveDisplayList` + `CGDisplayBounds` /
`CGDisplayCopyDisplayMode` to check a display's actual state,
`CGWarpMouseCursorPosition` + `CGEventCreate(nil)!.location` to simulate
cursor movement and confirm where it ends up) — this caught real bugs (see
architecture notes above) that a build-only check would have missed.
Drag tests can be scripted too: post `CGEvent` mouse-down / `leftMouseDragged` /
mouse-up through `.cghidEventTap` against a window with a plain title bar (TextEdit;
Finder's toolbar doesn't drag). Always send *relative* movement (each step = the
cursor's actual position + delta): absolute positions along a fixed line drag the
cursor straight back after every warp and make entries look broken.

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
