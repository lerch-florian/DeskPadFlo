# DeskPad (fork) — a virtual screen you can move the cursor and windows into

This is a fork of [Stengo/DeskPad](https://github.com/Stengo/DeskPad), built for live presentations: you share the virtual screen with a team and/or a connected external display, switch between windows freely, and keep an eye on exactly what is being shared in a preview window on your own screen.

The original DeskPad creates the virtual display and mirrors it in a window; the cursor only got into it by clicking the window, and windows only by being dragged across wherever macOS happened to arrange the displays. This fork makes that seamless: the cursor and dragged windows cross between your real screen and the virtual one directly, with a choice of how that behaves.

The original README follows [below](#original-readme-upstream-deskpad) unchanged.

## What's different from the original

### Cursor modes (Options menu)

| Mode | Behavior |
| --- | --- |
| **Seamless** | The cursor enters and leaves wherever the virtual screen is visible: onto any uncovered part of the preview window, and back out at the screen's borders — or wherever another window covers the spot the cursor maps to, so it continues onto that window without visibly moving. The preview window is never raised. |
| **Auto** *(default)* | The cursor enters wherever the virtual screen is visible and leaves at any border of the virtual screen. Entering (and clicking on the virtual screen) brings the preview window to the top. |
| **Click to Enter** | The cursor enters only when you click the preview window, and leaves at any border of the virtual screen. |

Entering maps the cursor to the same relative point on the virtual screen; leaving maps it back to the matching point on the preview window's edge. This works for fast mouse movements too (detection is based on crossing the boundary, not on landing in a thin band at the edge).

**Disconnect Screen from OS Arrangement** *(on by default)* — by default macOS places the virtual display right next to your main display, so the OS itself carries the cursor (and dragged windows) across the shared edge, competing with the jumps above. With this option the virtual display is arranged so that it touches your real displays only at a corner. macOS refuses gaps between displays but accepts corner-only contact, which leaves no shared edge to cross. A software hold stays active as a safety net. Turning the option off restores macOS's normal side-by-side placement.

**Emergency reset** — `⌘⌥⇧H` (system-wide) or Options → *Emergency: Move Cursor to Main Screen* puts the cursor in the middle of your main screen, in case it is ever stuck on the virtual one.

### Moving windows in and out

Windows are moved by the OS's own window drag, so no Accessibility permission is needed:

- **Seamless / Auto:** drag a window by its title bar onto the preview window — the cursor jumps into the virtual screen and the window follows. Drag it out through a border and it follows the cursor back. A dragged window is not treated as "covering" the preview, and after leaving it ends up above the preview window.
- **Click to Enter:** a window dragged over the preview window does not enter by itself. It enters when you **shake** the cursor while dragging, or press **`⌘⇧D`** while dragging over the preview. (`⌘⇧D` is only claimed system-wide for the duration of such a drag, so other apps keep it otherwise.)
- Dragging the **preview window itself** no longer causes it to jump around or end up on the (invisible) virtual display: while you hold it, no cursor jumps happen, and its centre can't be dragged onto the virtual display.

### Resolution

- The virtual display now starts at **a quarter of the host screen** (half the width, half the height — e.g. 840×525 on a 1680×1050 built-in screen), rendered at 2× so it stays sharp. The preview window opens at about a quarter of the screen as well, so the two match nearly 1:1.
- New **Resolution** menu: presets from 1280×800 up to 5120×2160, plus *Match Built-in Display*. Switching takes effect immediately, no trip to System Settings needed.

### Other changes

- The preview window is no longer raised merely because the cursor moved onto the virtual display; whether it is raised depends on the mode (see the table).
- Options are not persisted; DeskPad starts with the defaults above each time.
- The project can be built and run **without Xcode.app** (Command Line Tools are enough), see below.

## Using this fork

There are no prebuilt releases of the fork (the release binaries and the Homebrew cask in the original README below are the upstream app). Build it yourself.

### Building without Xcode

`scripts/build-dev.sh` builds the sources through a throw-away Swift package, refreshes `~/DeskPad.app` in place, re-signs it and launches it. The one-time setup (the package, the app bundle skeleton, and a **stable code-signing identity**) is described in [`CLAUDE.md`](CLAUDE.md).

The stable signing identity matters: with ad-hoc signing every rebuild looks like a brand-new app to macOS, so the Screen Recording permission has to be granted again after each build. Signing every build with the same (self-signed) certificate keeps the permission.

DeskPad needs the **Screen Recording** permission (see Troubleshooting in the original README below). It needs no Accessibility permission.

### Caveats

- `DeskPad.xcodeproj` has **not** been updated for the source files added in this fork, so it won't build them as is; the SwiftPM script is the supported way for now.
- The dev build runs unsandboxed and without the asset catalog (no app icon, no coloured title bar). A signed, sandboxed release build with the project's entitlements has not been tried with the new features.
- Tested on macOS 26 on a MacBook Pro (M1) with only the built-in display. Other display setups (several monitors, other resolutions) follow the same logic but are untested. The OS-level cursor clamping at the corner can't be measured with scripted events, so that is verified only by the arrangement read-back plus the software safety net.
- Window dragging relies on the OS's standard title-bar drag; apps with a custom-drawn title bar were not tried.

`CLAUDE.md` documents the architecture, the reasoning behind the non-obvious parts, and how the behavior is tested headlessly.

---

# Original README (upstream DeskPad)

<h3 align="center">
  <a href="https://github.com/Stengo/DeskPad/blob/main/DeskPad/Assets.xcassets/AppIcon.appiconset/Icon-256.png">
  <img src="https://github.com/Stengo/DeskPad/blob/main/DeskPad/Assets.xcassets/AppIcon.appiconset/Icon-256.png?raw=true" alt="DeskPad Icon" width="128">
  </a>
</h3>

# DeskPad
A virtual monitor for screen sharing

<h3 align="center">
  <a href="https://github.com/Stengo/DeskPad/blob/main/screenshot.jpg">
  <img src="https://github.com/Stengo/DeskPad/blob/main/screenshot.jpg?raw=true" alt="DeskPad Screenshot">
  </a>
</h3>

Certain workflows require sharing the entire screen (usually due to switching through multiple applications), but if the presenter has a much larger display than the audience it can be hard to see what is happening.

DeskPad creates a virtual display that is mirrored within its application window so that you can create a dedicated, easily shareable workspace.

# Installation
You can either download the [latest release binary](https://github.com/Stengo/DeskPad/releases) or install via [Homebrew](https://brew.sh) by calling `brew install --cask deskpad`.

# Usage
DeskPad behaves like any other display. Launching the app is equivalent to plugging in a monitor, so macOS will take care of properly arranging your windows to their previous configuration.

You can change the display resolution through the system preferences and the application window will adjust accordingly.

Whenever you move your mouse cursor to the virtual display, DeskPad will highlight its title bar in blue and move the application window to the front to let you know where you are.

<h3 align="center">
  <a href="https://github.com/Stengo/DeskPad/blob/main/demonstration.gif">
  <img src="https://github.com/Stengo/DeskPad/blob/main/demonstration.gif?raw=true" alt="DeskPad Demonstration">
  </a>
</h3>

# Troubleshooting
DeskPad may need screen recording permissions to display properly. Follow these steps:

1. **Open System Settings** → **Privacy & Security** → **Screen Recording**
2. **Enable DeskPad** by checking the box next to it
3. **If DeskPad appears but isn't working:**
   - Uncheck the DeskPad option
   - Check it again to re-enable
4. **Restart DeskPad** for changes to take effect
