# Ergodox EZ Keyboard Configuration

QMK firmware configuration for Ergodox EZ, managed via Nix.

## Keymap Design

### Philosophy

- **Portable**: Standard QWERTY base layer works on any keyboard
- **Minimal**: 2 layers keep mental overhead low
- **Ergonomic**: Home row mods reduce finger travel
- **Vim-friendly**: Arrow keys on HJKL (layer + HJKL)
- **Dev-optimized**: Programming brackets easily accessible

### Layer 0: BASE (QWERTY + Home Row Mods)

```
,--------------------------------------------------.           ,--------------------------------------------------.
|   `    |   1  |   2  |   3  |   4  |   5  |      |           |      |   6  |   7  |   8  |   9  |   0  |   -    |
|--------+------+------+------+------+-------------|           |------+------+------+------+------+------+--------|
| Escape |   Q  |   W  |   E  |   R  |   T  |  [   |           |   ]  |   Y  |   U  |   I  |   O  |   P  |   =    |
|--------+------+------+------+------+------|      |           |      |------+------+------+------+------+--------|
|Tab/MO1 | A/GUI| S/Alt| D/Sft| F/Ctl|   G  |------|           |------|   H  | J/Ctl| K/Sft| L/Alt| ;/GUI|   '    |
|--------+------+------+------+------+------|  (   |           |   )  |------+------+------+------+------+--------|
| LShift |   Z  |   X  |   C  |   V  |   B  |      |           |      |   N  |   M  |   ,  |   .  |   /  | RShift |
`--------+------+------+------+------+-------------'           `-------------+------+------+------+------+--------'
  |      |      |      |      |      |                                       |      |      |      |   \  |      |
  `----------------------------------'                                       `----------------------------------'
                                       ,-------------.       ,-------------.
                                       |      |      |       |      |      |
                                ,------|------|------|       |------+------+------.
                                |      |      |      |       |      |      |      |
                                | Space| Bksp |------|       |------| Del  |Enter |
                                |      |      | Esc  |       | Tab  |      |      |
                                `--------------------'       `--------------------'
```

**Layer key (Tab/MO1):**

- Tap for Tab
- Hold to access Layer 1 (FUNC)

**Home Row Mods (GASC pattern):**

- A/GUI, S/Alt, D/Shift, F/Ctrl (left hand)
- J/Ctrl, K/Shift, L/Alt, ;/GUI (right hand)
- Tap for letter, hold for modifier

**Programming brackets:**

- `[` `]` on inner columns (easy access)
- `(` `)` below (programming flow)

### Layer 1: FUNC (Navigation + F-Keys)

```
,--------------------------------------------------.           ,--------------------------------------------------.
| Escape |  F1  |  F2  |  F3  |  F4  |  F5  |      |           |      |  F6  |  F7  |  F8  |  F9  | F10  |  F11   |
|--------+------+------+------+------+-------------|           |------+------+------+------+------+------+--------|
|        | Vol+ | Mute | Next | Bri+ |      |      |           |      |      |      |      |      | PrScr|  F12   |
|--------+------+------+------+------+------|      |           |      |------+------+------+------+------+--------|
| [held] | Vol- | Play | Prev | Bri- |      |------|           |------| Left | Down |  Up  |Right |      |        |
|--------+------+------+------+------+------|      |           |      |------+------+------+------+------+--------|
|        |      |      |      |      |      |      |           |      | Home | PgDn | PgUp | End  |      |        |
`--------+------+------+------+------+-------------'           `-------------+------+------+------+------+--------'
  |QK_BOOT|     |      |      |      |                                       |      |      |      |      |      |
  `----------------------------------'                                       `----------------------------------'
                                       ,-------------.       ,-------------.
                                       |      |      |       |      |      |
                                ,------|------|------|       |------+------+------.
                                |      |      |      |       |      |      |      |
                                |      |      |------|       |------|      |      |
                                |      |      |      |       |      |      |      |
                                `--------------------'       `--------------------'
```

**Navigation:**

- HJKL → Arrow keys (vim muscle memory preserved)
- Home/End, PgUp/PgDn below arrows

**Media controls:**

- Volume, play/pause, brightness (left hand)

**Function keys:**

- F1-F12 across top row
- QK_BOOT in corner for flashing firmware

## Building

Build firmware using Nix from the repository root:

```bash
nix build .#ergodox-firmware
```

The compiled firmware will be at `./result/ergodox_ez_base_kyleondy.hex`.

## Flashing

### Method 1: Interactive Flake App (Recommended)

```bash
nix run .#flash-ergodox
```

This will:

1. Build the firmware
2. Prompt you to put the keyboard in bootloader mode
3. Flash automatically

### Method 2: Using Make

```bash
# From the keyboard directory
cd keyboard
nix develop --command make flash
```

Or from the repository root:

```bash
nix develop --command make -C keyboard flash
```

### Method 3: Manual Flashing

```bash
# Build the firmware
nix build .#ergodox-firmware

# Put keyboard in bootloader mode:
# - Press the physical reset button on the Ergodox EZ, OR
# - Press QK_BOOT key (Layer + bottom-left corner)

# Flash
nix develop
teensy-loader-cli -mmcu=atmega32u4 -w result/ergodox_ez_base_kyleondy.hex -v
```

Or use the [Teensy Loader GUI](https://www.pjrc.com/teensy/loader.html).

## Development

Enter development shell with QMK tools:

```bash
nix develop
```

This provides:

- `qmk` - QMK CLI for manual compilation
- `teensy-loader-cli` - Firmware flashing tool

## Configuration

- **`keymap.c`** - Keymap layout and layer definitions
- **`config.h`** - QMK behavior settings (tapping term, home row mods)
- **`rules.mk`** - QMK feature flags
- **`default.nix`** - Nix derivation for building firmware

## Home Row Mods Tuning

If home row mods feel too sensitive or trigger accidentally:

**Increase tapping term** (in `config.h`):

```c
#define TAPPING_TERM 250  // Default: 200ms
```

**Disable per-key hold behavior**:
Remove or comment out `#define HOLD_ON_OTHER_KEY_PRESS`

## Helpful Links

- [QMK Documentation](https://docs.qmk.fm/)
- [QMK Keycodes Reference](https://docs.qmk.fm/keycodes)
- [Home Row Mods Guide](https://precondition.github.io/home-row-mods)
- [Ergodox EZ Official Docs](https://ergodox-ez.com/)
