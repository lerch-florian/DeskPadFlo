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

**Shortcuts** — Options → *Shortcuts…* lets you change both keyboard shortcuts (the emergency reset and the drag shortcut below): click a shortcut, press the new combination, Esc cancels, *Reset* restores the default. Combinations that would catch normal typing or that macOS reserves (e.g. `⌘Q`) are refused. Your choices are remembered.

### Moving windows in and out

Windows are moved by the OS's own window drag, so no Accessibility permission is needed:

- **Seamless / Auto:** drag a window by its title bar onto the preview window — the cursor jumps into the virtual screen and the window follows. Drag it out through a border and it follows the cursor back. A dragged window is not treated as "covering" the preview, and after leaving it ends up above the preview window.
- **Click to Enter:** a window dragged over the preview window does not enter by itself. It enters when you **shake** the cursor while dragging, or press **`⌘⇧D`** while dragging over the preview. (`⌘⇧D` is only claimed system-wide for the duration of such a drag, so other apps keep it otherwise.)
- Dragging the **preview window itself** no longer causes it to jump around or end up on the (invisible) virtual display: while you hold it, no cursor jumps happen, and its centre can't be dragged onto the virtual display.

### Resolution

- The virtual display now starts at **a quarter of the host screen** (half the width, half the height — e.g. 840×525 on a 1680×1050 built-in screen), rendered at 2× so it stays sharp. The preview window opens at about a quarter of the screen as well, so the two match nearly 1:1.
- New **Resolution** menu: presets from 1280×800 up to 5120×2160, plus *Match Built-in Display*. Switching takes effect immediately, no trip to System Settings needed. The resolution you pick is remembered; *Quarter of Built-in Display (default)* goes back to the default, which then follows your screen again.

### Other changes

- The preview window is no longer raised merely because the cursor moved onto the virtual display; whether it is raised depends on the mode (see the table).
- Your settings are remembered between launches: the cursor mode, disconnecting the screen, the resolution you pick, and your keyboard shortcuts.
- The project can be built, packaged and released **without Xcode.app and without a paid Apple account**; see Installing below.

## Installing this fork

DeskPad needs macOS 13 or later and runs on Apple silicon and Intel Macs. It is **not notarized** (that requires a paid Apple Developer account), so macOS will not simply open a copy downloaded in the browser. The first option avoids that:

**1. One command (recommended)** — installs the latest release to `/Applications` without any Gatekeeper prompt:

```bash
curl -fsSL https://raw.githubusercontent.com/lerch-florian/DeskPadFlo/main/scripts/install.sh | bash
```

(`curl` doesn't mark the download as "from the internet", which is the only thing Gatekeeper checks. Read [`scripts/install.sh`](scripts/install.sh) first if you like; it is short, needs no `sudo`, and verifies the app's signature.)

**2. Manual download** — get `DeskPad.zip` from the [Releases page](https://github.com/lerch-florian/DeskPadFlo/releases), unzip it and drag `DeskPad.app` to Applications. On first launch macOS refuses; open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to the DeskPad message. (Or run `xattr -dr com.apple.quarantine /Applications/DeskPad.app` once.)

**3. Build it yourself** — only the free Command Line Tools are needed (`xcode-select --install`), not Xcode:

```bash
git clone https://github.com/lerch-florian/DeskPadFlo.git && cd DeskPadFlo
scripts/package-release.sh      # builds a universal dist/DeskPad.app and dist/DeskPad.zip
```

### First launch: Screen Recording permission

macOS asks for the **Screen Recording** permission the first time (System Settings → Privacy & Security → Screen Recording → enable DeskPad), then DeskPad has to be started once more. Until it is granted the window shows a short explanation with a button that opens the right Settings page. It needs no Accessibility permission. Releases are signed with the same certificate every time, so the permission carries over when you update. Builds you make yourself are signed ad-hoc by default and need the permission again after each rebuild; the tip in [`CLAUDE.md`](CLAUDE.md) (a stable self-signed certificate) removes that for development.

### Contributing

- `scripts/build-dev.sh` rebuilds, signs and relaunches `~/DeskPad.app` for development; `scripts/package-release.sh` makes the release archive (see its header for signing options). [`CLAUDE.md`](CLAUDE.md) documents the architecture, the reasoning behind the non-obvious parts, the signing/distribution setup and how the behavior is tested headlessly.
- A root `Package.swift` makes `swift build` work from a clone. The Xcode project is kept in step by hand (new files, bundle ID) but has not been built in Xcode. It still names the upstream author's signing team, so choose your own (a free Apple ID works) or "Sign to Run Locally".

### Caveats

- Tested on macOS 26 on a MacBook Pro (M1) with only the built-in display. Other display setups (several monitors, other resolutions) follow the same logic but are untested. The Intel half of the universal binary builds but has not been run.
- Whether macOS can carry the cursor diagonally through exactly the corner pixel when the screen is disconnected can't be measured with scripted events; the software safety net covers it.
- Window dragging relies on the OS's standard title-bar drag; apps with a custom-drawn title bar were not tried.
- The app runs in the App Sandbox with the original project's entitlements; the cursor, drag, shake and shortcut features were verified to work that way.

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
