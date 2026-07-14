# helios

Hand-rolled photo management CLI. Imports photos off cameras and the
filesystem with content dedup, and manages Fujifilm camera settings over USB.

```
helios import camera            # pull photos off a connected camera
helios import filesystem SRC    # import a directory of photos
helios fuji-settings backup     # whole-camera settings backup (.bak)
helios fuji-settings restore    # write a .bak back to the camera
helios fuji-recipes             # film recipe management, see below
```

## Film recipes

Film recipes in the [fujixweekly](https://fujixweekly.com/) sense: a named
bundle of film simulation, white balance, tone, and grain settings stored in
one of the camera's C1-C7 custom slots. The `fuji-recipes` commands read and
write those slots directly, one YAML file per recipe.

The whole-blob `backup`/`restore` still exists and covers everything the
camera stores, recipes included. Recipes are the editable, per-slot view.

### Camera setup

1. On the camera, set CONNECTION MODE (on some bodies CONNECTION SETTING >
   CONNECTION MODE) to USB RAW CONV./BACKUP RESTORE.
2. Connect the USB cable. The screen should show the RAW conversion mode.

That is the same mode the blob backup uses. Nothing else to configure.

### Take a full backup first

Recipe restore writes to the camera. Take a cheap safety net first:

```
helios fuji-settings backup
```

That writes `MODEL-DATE.bak`. If a recipe write ever leaves a slot in a weird
state, `helios fuji-settings restore MODEL-DATE.bak` puts everything back.

### Usage

```
# see what is on the camera
helios fuji-recipes list
helios fuji-recipes list --dump-raw   # raw property values, for debugging

# camera slots -> files (c1-<name>.yaml .. c7-<name>.yaml)
helios fuji-recipes backup --dir ./recipes
helios fuji-recipes backup --slots 1,3

# file -> camera slot
helios fuji-recipes restore kodachrome-64.yaml --slot 3

# whole directory -> camera, mapping c1-*.yaml to C1 and so on
helios fuji-recipes restore --dir ./recipes

# pasted fujixweekly text -> recipe file
helios fuji-recipes import recipe.txt
pbpaste | helios fuji-recipes import -
```

`restore` shows the connected model and a summary of what it is about to
write, then asks. `--yes` skips the prompt. After a restore the camera can
take a second to show the new values in its menus; power cycling never hurts.

`import` is fuzzy about labels and reports every line as parsed, kept as a
comment, or unrecognized. Unrecognized lines mean you should check the output
file by hand.

### Recipe files

One YAML file per recipe. Everything is hand-editable:

```yaml
name: Kodachrome 64
film_simulation: Classic Chrome
dynamic_range: 200
grain: Weak/Small
color_chrome: Strong
color_chrome_fx_blue: "Off"
white_balance: Daylight
wb_shift_r: 2
wb_shift_b: -5
highlight_tone: 1.0
shadow_tone: 1.0
color: 2.0
sharpness: 1.0
high_iso_nr: -4
clarity: 0.0
```

Field notes:

- **film_simulation**: camera menu names, fuzzy matched ("classic chrome",
  "Classic Neg", "Acros+Ye"). A bare integer also works, for simulations we
  do not know about yet.
- **dynamic_range**: 100, 200, or 400. DR-Auto is not storable in a slot.
- **grain**: Off, Weak/Small, Strong/Small, Weak/Large, Strong/Large.
- **color_chrome, color_chrome_fx_blue, smooth_skin**: Off, Weak, Strong.
  Quote "Off" in YAML or it parses as a boolean; the loader tolerates both.
- **white_balance**: Auto, Daylight, Shade, Incandescent, Fluorescent 1-3,
  Underwater, Auto Ambience Priority, Color Temp. Color Temp requires
  `wb_color_temp` in Kelvin.
- **wb_shift_r, wb_shift_b**: -9 to 9.
- **highlight_tone, shadow_tone, color, sharpness, clarity**: camera ranges,
  in halves. `color` does not apply to monochrome simulations; leave it out.
- **high_iso_nr**: -4 to 4.
- **mono_wc, mono_mg**: monochromatic color toning, -9 to 9, monochrome
  simulations only.
- **passthrough**: raw values we round trip verbatim (image size, image
  quality, color space, long exposure NR, two unknowns). Leave it alone
  unless you know the encoding. Files without it get sane defaults.

### Limitations

- **ISO and exposure compensation are not stored.** They are shooting
  parameters, not part of a custom slot. The camera's own EDIT/SAVE CUSTOM
  SETTING menu has no ISO entry either. `import` keeps those lines as
  comments in the file so the guidance is not lost.
- **Stills slots only.** The X-T5 has a separate C1-C7 bank for movie mode,
  but the protocol for it is unmapped. Video settings are still covered by
  the whole-blob backup.
- **Encodings confirmed on the X100VI.** Other X-Processor 5 bodies should
  behave the same but have not all been tested. Rejected writes come back as
  warnings, not silent corruption, and `--dump-raw` shows what the camera
  actually stores.
- **Older bodies will not work.** X-Processor 4 and earlier do not expose the
  preset properties. The support check fails with a clear error instead of
  writing garbage.

### Protocol

Custom slots are plain PTP device properties in the RAW CONV./BACKUP RESTORE
USB mode: 0xD18C selects the slot, 0xD18D is the name, 0xD18E-0xD1A5 are the
settings. Reverse engineered by the
[filmkit](https://github.com/eggricesoy/filmkit/tree/9e3bbcf858b1) project
from Wireshark captures of Fujifilm X RAW Studio; see `src/ptp/constants.ts`
and `src/profile/preset-translate.ts` there for the property map. The blob
backup protocol comes from
[libfuji](https://github.com/petabyt/libfuji/blob/782f9c657ece16890f67343fb5560294d802f94f/lib/fuji_usb.c#L173-L242).
