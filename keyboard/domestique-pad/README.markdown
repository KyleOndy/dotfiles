# domestique pad

Two switches on an Adafruit KB2040, wired to hand while riding. The pad is one
end of a protocol and does nothing on its own: Karabiner turns each key into a
file under `~/.local/state/domestique`, and the domestique watchers read those.

## Signals

| gesture      | keycode | file        | what happens                                             |
| ------------ | ------- | ----------- | -------------------------------------------------------- |
| key 1 held   | F13     | `listening` | microphone opens, transcript goes to the alamode session |
| key 2 tapped | F16     | `replay`    | re-speak the last reply; N taps replays N replies        |
| both held    | F17     | `outofband` | transcript goes to `notes.md`, never into context        |

F16 and F17 rather than F14 and F15: macOS binds F14 and F15 to display
brightness, and that binding only appears in System Settings once a keyboard
carrying those keys is attached. F13 and F16 through F20 are the free ones.

The chord is resolved in firmware with a QMK combo rather than in Karabiner.
Karabiner's `simultaneous` has a detection window that lets a sloppy press open
channel 1 _and_ channel 2; a combo emits a third keycode and suppresses both
singles, so Karabiner sees three unambiguous keys. The chord is a hold rather
than a press, because an out-of-band utterance can end the alamode session:
`COMBO_MUST_HOLD_PER_COMBO` is on, `get_combo_must_hold()` returns true, and
`COMBO_HOLD_TERM` is 200 ms.

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
connector), and GP26-GP29, which are the only ADC pins and therefore the only
way to ever add a potentiometer or a brake lever.

The board's NeoPixel (GP17) lights while a switch is closed: green for key 1,
blue for key 2, cyan for both. It reads the switches directly, ahead of the
combo and USB, so a press that leaves it dark is wiring, and one that lights it
but changes nothing on the Mac is Karabiner or the host.

## Build and flash

```bash
git add keyboard/domestique-pad   # the flake reads the git tree
nix run .#flash-pad
```

`flash-pad` builds, waits for the board to mount as `RPI-RP2`, copies the
`.uf2`, and times out with a message rather than copying nowhere.

Entering the bootloader:

- **First flash ever**, or after any firmware that will not boot: hold the
  board's **BOOT** button while plugging in, or double-tap **RESET**. The pad
  ships with CircuitPython, so BOOTMAGIC is not there yet.
- **Every flash after that**: hold **key 1** while plugging in. That is QMK
  Bootmagic (`features.bootmagic` in `keyboard.json`) on its default matrix
  position `[0,0]` ([QMK 0.27.3 bootmagic.md][qmk-bootmagic]).

Because BOOTMAGIC shares a switch with push-to-talk, plugging the pad in with a
finger resting on key 1 mounts it as a drive instead of a keyboard. No cue rings;
unplug and replug.

### Probe

```bash
nix run .#flash-pad -- probe
```

A second build for finding where a wire landed. Every pin on the headers is a
key, and closing one to GND types its silkscreen label (`D4`, `A0`, `MOSI`) into
whatever has focus. A pin already shorted to GND types its label once at
plug-in. Two pins shorted to each other type as a pair (`D6-D7`), which is what
a switch makes when its common wire landed on a D pin instead of GND. It has no
BOOTMAGIC, so getting back to the pad build means BOOT or a double-tap of RESET,
then `nix run .#flash-pad`.

## After flashing

The Karabiner rules are gated on the pad's USB identifiers, so they are inert
until those match. `usb.vid` and `usb.pid` in `keyboard.json` declare `0xFEED`
and `0xD065`, but what the rules must carry is what macOS actually enumerates.
Open Karabiner-EventViewer, press each key, and confirm both the identifiers and
that F13/F16/F17 arrive. A mismatch fails silently: the keys do nothing and
nothing says why.

[qmk-bootmagic]: https://github.com/qmk/qmk_firmware/blob/0.27.3/docs/features/bootmagic.md

## Case

The case is OpenSCAD, in `case/`. Every part includes `params.scad`, which
holds each measured fit, so a fit found on a test print changes in one place.

```bash
nix run .#pad-case                    # every part, to case/out/<part>.3mf
nix run .#pad-case -- fit-test        # only the named parts
nix run .#pad-case -- edit fit-test   # OpenSCAD GUI, redraws on every save
```

It reads the `.scad` files from the worktree, so an edit renders without a
`git add`. It is an app and not a package because openscad 2021.01 segfaults
inside trex's darwin build sandbox, even on `cube(5)`. Each render prints the
part's size and fails if it is larger than the A1 mini's 180 mm bed.

OpenSCAD exports 3MF and STL but not STEP. Onshape can import the 3MF as a
mesh to measure against, not to edit, so the `.scad` is the only source.

### Fit test

Print `fit-test.3mf` in the filament the case will use, since a fit measured in
one plastic does not carry over to another. Each piece has its value engraved.

- **Clip slices** (20.6, 21.0, 21.4 mm mouth): snap each onto an extension and
  keep the one that grips without a fight. 21.0 is the Onshape V8 crossbar's.
- **Switch strip** (13.9, 14.0, 14.1 mm cutout): press a switch into each and
  keep the one it clicks into without rattling.
- **Rail and foot**: drop an M3 nut into each pocket (5.6, 5.8 mm across the
  flats), bolt the foot down through the slot with M3x12s from below, and slide
  it. The pocket a nut drops into and stays in is the one.

### Bar pod

`bar-pod.3mf` holds the two switches stacked across the base bar, facing
forward. It sits on the bar tape in a saddle that wraps 55 degrees either side
of the bar's front, held on by a strap through its body: a 1/2" velcro strap,
or two zip ties up to 4.8 mm wide. The bays under the switches open to both
sides for the wires.

The saddle is cut to `bar_diameter` in `params.scad`, measured over the tape
where the pod sits: wrap a strip of paper once around the bar, mark where it
overlaps, and divide that length by pi. A V-groove sized for the 22.3 mm
extensions sat only on its two edges there.

### Carrier

`carrier.3mf` holds the KB2040 under a straight stretch of one extension, near
the base bar and clear of the hands. It is 70 mm long and snaps on with the fit
test's 20.6 mm clip over the middle 50 mm, USB-C toward the base bar. Zip-tie
the cable to the tube behind it, since a single clip can turn on the tube.

A pod plugs into a JST XH header in the front face, so the board's own wiring
is soldered once. The wires run forward in a channel beside the board's D-pin
edge, then cross a 25 mm open bay to the header's tails, so the iron has room
on every joint.

1. On the bench, solder about 70 mm of wire to the tops of GND and D4 through
   D7, all on one edge. Black goes to GND. The others go to D4 through D7 in
   the order they sit in a pod's plug, starting next to black. Trim anything
   poking out the bottom flush, since the board lies flat on the pocket floor.
2. Plug a pigtail into a 5-pin XH header and push the header into the front
   face, pins first, so the tails come through the plate into the bay. Turn it
   so black sits at the end farther from the channel. Leave the pigtail in
   while soldering; it holds the pins straight if the PLA softens.
3. Drop the board in with USB-C in the notch at the back and lay the wires in
   the channel. Solder each to the tail that carries its color in the pigtail.
   Those joints hold the header in when a plug is pulled, so keep them quick.
4. Slide the lid in from the back, its window over the end of the board.

BOOT and RESET show through the window, BOOT nearer the channel. A fingernail
reaches them with the carrier on the bike, so entering the bootloader (Build
and flash above) never means taking it apart.

A pod's leads are a 5-pin XH plug and its 200 mm pigtail, the free ends
soldered to the switches as in Wiring above. A pod farther than that from the
carrier needs its leads spliced longer. A two-key pod cuts the D6 and D7 leads
short, and firmware only reads GP6 and GP7 once a pod wires them.
