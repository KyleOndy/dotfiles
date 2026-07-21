# trex Configuration

Personal darwin (macOS) configuration for trex. Shared darwin plumbing lives in
`nix/modules/darwin_modules/`.

## Manual Setup Required

A few Homebrew casks manage apps whose own permissions or sandboxed prefs can't be
set declaratively. Each needs a one-time manual step after first install.

### Shottr Screenshot Tool

Shottr is installed via Homebrew but requires manual configuration because it uses a
sandboxed container that prevents automated `defaults write` commands from working
until after the first launch.

#### Initial Setup

1. Launch Shottr once to initialize its sandboxed container.
2. Grant **Screen Recording** permission when prompted (System Settings -> Privacy &
   Security -> Screen Recording).
3. Open Shottr Preferences and configure the following settings.

#### Recommended Settings

**General:**

- Default save location: `~/screenshots` (auto-created and added to the Finder
  sidebar by the `finder-sidebar` launchd agent)
- After capture:
  - Copy to clipboard
  - Save to disk
  - Show preview window

**Shortcuts:**

- Fullscreen screenshot: `Cmd+Shift+3`
- Area screenshot: `Cmd+Shift+4`

> macOS's own screenshot shortcuts are disabled via `com.apple.symbolichotkeys` in
> `configuration.nix`, so Shottr can claim these key combinations. The Kensington
> trackball's top-right and top-left buttons are remapped by Karabiner-Elements to
> these same shortcuts (see below), so a trackball button press triggers a Shottr
> capture directly.

**Capture:**

- Area capture mode: Preview
- Color format: HEX
- Snapping mode: Smart snapping
- Capture cursor: Auto
- Expandable canvas: On

**Appearance:**

- Window shadow: Transparent
- Always on top: Off

**Thumbnail:**

- Thumbnail closing: Manual
- Copy on Esc: On

#### Why Not Automated?

Shottr stores preferences in
`~/Library/Containers/cc.ffitch.shottr/Data/Library/Preferences/cc.ffitch.shottr.plist`.
This sandboxed container directory doesn't exist until Shottr is launched for the
first time. Attempting to write preferences via `defaults write` before this
directory exists will fail silently or write to the wrong location.

#### Verifying Configuration

```bash
defaults read cc.ffitch.shottr
```

### Karabiner-Elements (Kensington Expert Trackball)

The button remapping rules are generated declaratively by home-manager
(`hmFoundry.desktop.input.karabiner.kensingtonExpert.enable = true` in `home.nix`),
but Karabiner-Elements itself needs one-time OS approval after install:

1. Launch Karabiner-Elements.
2. Approve its driver / system extension and grant **Input Monitoring** permission
   in System Settings -> Privacy & Security.
3. Confirm the Kensington Expert Trackball appears under Devices - Karabiner matches
   it by USB vendor/product ID (1149 / 4128), so this works automatically whenever
   the trackball is connected, including hotplug when docking.

Once approved, the trackball's top-right button sends Cmd+Shift+3 (Shottr fullscreen
capture) and the top-left button sends Cmd+Shift+4 (Shottr region capture).

### Hammerspoon

Enabled in `home.nix` for app quick-switching. After install, launch it once and
grant **Accessibility** permission in System Settings -> Privacy & Security.

## Deployment

```bash
make build-trex-dry   # dry run
make build-trex        # build
make deploy-trex       # darwin-rebuild --flake .#trex switch
```
