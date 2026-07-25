# trex Configuration

Personal darwin (macOS) configuration for trex. Shared darwin plumbing lives in
`nix/modules/darwin_modules/`.

## Manual Setup Required

A few Homebrew casks manage apps whose own permissions or sandboxed prefs can't be
set declaratively. Each needs a one-time manual step after first install.

### Shottr Screenshot Tool

Shottr keeps its preferences in a sandboxed container at
`~/Library/Containers/cc.ffitch.shottr/Data/Library/Preferences/cc.ffitch.shottr.plist`.
That directory does not exist until Shottr has launched once, so `defaults write`
before first launch fails silently or writes to the wrong location. Hence the
manual steps.

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
> `configuration.nix`, so Shottr can claim these key combinations.

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

#### Verifying Configuration

```bash
defaults read cc.ffitch.shottr
```

### Karabiner-Elements (Kensington Expert Trackball)

The button remapping rules are generated declaratively by home-manager
(`hmFoundry.desktop.input.karabiner.enable = true` in `home.nix`; the trackball
rule is unconditional once the module is on),
but Karabiner-Elements itself needs one-time OS approval after install:

1. Launch Karabiner-Elements.
2. Approve its driver / system extension and grant **Input Monitoring** permission
   in System Settings -> Privacy & Security.
3. Confirm the Kensington Expert Trackball appears under Devices - Karabiner matches
   it by USB vendor/product ID (1149 / 4128), so this works automatically whenever
   the trackball is connected, including hotplug when docking.

Once approved, the trackball's top-right button sends Cmd+Shift+3 (Shottr fullscreen
capture) and the top-left button sends Cmd+Shift+4 (Shottr region capture).

### AltTab

Installed as a cask for app switching. macOS only draws its own switcher when
Cmd+Tab is held, so a quick tap silently swaps to the previous app. After
install, launch it once and grant **Accessibility** and **Screen Recording**
permission in System Settings -> Privacy & Security, then set its trigger to
Cmd+Tab in its preferences.

## tiger's SMB Shares

Two shares mount at login and show up under Locations in the Finder sidebar:

- **/Volumes/tiger-data** - `/mnt/data` on tiger, general files.
- **/Volumes/tiger-photos** - `/mnt/photos` on tiger, the photo dump. Note that
  `backup-photos-to-dr.sh` rsyncs into it with `--delete`, so anything written
  there by hand disappears on the next sync.

No manual setup. The `smb-tiger-mount` launch agent (`home.nix`) mounts whatever
is not mounted, at login and every five minutes after, which also covers
reconnects after sleep or a network drop. It logs to
`~/Library/Logs/smb-tiger.log`.

Two things about it are less obvious than they look:

- **It lives in `home.nix`, not `configuration.nix`.** nix-darwin's
  `launchd.agents` bootstraps into the system domain and runs as root, which
  mounts the shares for the wrong user. home-manager's runs as kyle in
  `gui/501`.
- **It calls `mount_smbfs` with the sops password, not NetFS.** An item written
  by `security add-internet-password` is not in the keychain's `apple:`
  partition, so NetAuthAgent will not read it unattended and every mount
  becomes a login-time password dialog. Repairing that needs the macOS login
  password passed to `security set-internet-password-partition-list -k`, which
  is worse than what it fixes.

The mount points are created by an activation script in `configuration.nix`,
since /Volumes is root-owned and the agent is not.

tiger is addressed as `tiger.dmz.1ella.com`, not `tiger.local`. trex sits on
10.24.89.0/24 and tiger on 10.25.89.0/24, and mDNS does not cross subnets.

If the volumes mount but never appear in the sidebar, check Finder -> Settings
-> Sidebar -> Locations -> Connected servers.
