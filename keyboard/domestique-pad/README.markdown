# domestique pad

Two switches on an Adafruit KB2040, wired to hand while riding. The pad is one
end of a protocol and does nothing on its own: Karabiner turns each key into a
file under `~/.pi/domestique`, and the domestique watchers read those.

## Signals

| gesture      | keycode | file        | what happens                                        |
| ------------ | ------- | ----------- | --------------------------------------------------- |
| key 1 held   | F13     | `listening` | microphone opens, transcript goes to the pi session |
| key 2 tapped | F16     | `replay`    | re-speak the last reply; N taps replays N replies   |
| both held    | F17     | `outofband` | transcript goes to `notes.md`, never into context   |

F16 and F17 rather than F14 and F15: macOS binds F14 and F15 to display
brightness, and that binding only appears in System Settings once a keyboard
carrying those keys is attached. F13 and F16 through F20 are the free ones.

The chord is resolved in firmware with a QMK combo rather than in Karabiner.
Karabiner's `simultaneous` has a detection window that lets a sloppy press open
channel 1 _and_ channel 2; a combo emits a third keycode and suppresses both
singles, so Karabiner sees three unambiguous keys. `COMBO_MUST_HOLD` guards the
chord because an out-of-band utterance can end the pi session.

The cost is `COMBO_TERM`: QMK cannot emit either single key until it knows the
other is not coming, so both are delayed by that much on key-down. Invisible for
push-to-talk, since nobody has started speaking yet.

## Wiring

```
switch 1:  GP4 (silkscreen D4)  <-->  GND
switch 2:  GP5 (silkscreen D5)  <-->  GND
```

`DIRECT_PINS` configures each as input-pullup and reads active-low, so there are
no resistors and no diodes. Silkscreen `Dn` is `GPn` for n in 2..10.

Left free deliberately: GP0/GP1 (UART), GP12/GP13 (wired to the STEMMA QT
connector), GP17 (NeoPixel), and GP26-GP29, which are the only ADC pins and
therefore the only way to ever add a potentiometer or a brake lever.

## Build and flash

```bash
git add keyboard/domestique-pad   # the flake reads the git tree
make flash-pad
```

`make flash-pad` builds, waits for the board to mount as `RPI-RP2`, copies the
`.uf2`, and times out with a message rather than copying nowhere.

Entering the bootloader:

- **First flash ever**, or after any firmware that will not boot: hold the
  board's **BOOT** button while plugging in, or double-tap **RESET**. The pad
  ships with CircuitPython, so BOOTMAGIC is not there yet.
- **Every flash after that**: hold **key 1** while plugging in. That is
  `BOOTMAGIC_LITE` on matrix position `[0,0]`.

Because BOOTMAGIC shares a switch with push-to-talk, plugging the pad in with a
finger resting on key 1 mounts it as a drive instead of a keyboard. No cue rings;
unplug and replug.

## After flashing

The Karabiner rules are gated on the pad's USB identifiers, so they are inert
until those match. `usb.vid` and `usb.pid` in `keyboard.json` declare `0xFEED`
and `0xD065`, but what the rules must carry is what macOS actually enumerates.
Open Karabiner-EventViewer, press each key, and confirm both the identifiers and
that F13/F16/F17 arrive. A mismatch fails silently: the keys do nothing and
nothing says why.
