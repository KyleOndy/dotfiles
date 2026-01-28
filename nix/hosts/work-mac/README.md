# Work Mac Configuration

This directory contains nix-darwin configuration for macOS work environments.

## Manual Setup Required

### Shottr Screenshot Tool

Shottr is installed via Homebrew but requires manual configuration because it uses a sandboxed container that prevents automated `defaults write` commands from working until after the first launch.

#### Initial Setup

1. Launch Shottr once to initialize its sandboxed container
2. Open Shottr Preferences
3. Configure the following settings:

#### Recommended Settings

**General:**

- Default save location: `~/screenshots` (this directory is auto-created and added to Finder sidebar)
- After capture:
  - ✅ Copy to clipboard
  - ✅ Save to disk
  - ✅ Show preview window

**Shortcuts:**

- Fullscreen screenshot: `Cmd+Shift+3`
- Area screenshot: `Cmd+Shift+4`

> Note: macOS screenshot shortcuts are automatically disabled via `com.apple.symbolichotkeys` in the nix-darwin config, allowing Shottr to intercept these key combinations.

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

Shottr stores preferences in `~/Library/Containers/cc.ffitch.shottr/Data/Library/Preferences/cc.ffitch.shottr.plist`. This sandboxed container directory doesn't exist until Shottr is launched for the first time. Attempting to write preferences via `defaults write` before this directory exists will fail silently or write to the wrong location.

#### Verifying Configuration

After configuring manually, you can verify settings with:

```bash
defaults read cc.ffitch.shottr
```

## Deployment

Deploy configuration changes with:

```bash
make HOSTNAME=work-mac deploy
```
