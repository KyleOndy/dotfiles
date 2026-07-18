# helios

Hand-rolled photo management CLI. Imports photos off cameras and the
filesystem with content dedup, and manages Fujifilm camera settings over USB.

```
helios import camera            # pull photos off a connected camera
helios import filesystem SRC    # import a directory of photos
helios fuji-settings backup     # whole-camera settings backup (.bak)
helios fuji-settings restore    # write a .bak back to the camera
helios fuji-settings inspect F  # decode a backup's per-slot settings (recipe + auto-ISO)
helios fuji-settings edit F     # edit a slot in a backup file offline (recomputes checksum)
helios fuji-settings diff A B   # diff backups to map what a setting changed
helios fuji-settings correlate  # locate blob offsets by matching known recipes
helios fuji-settings commit-probe # find the bytes the camera re-stamps on save (RE aid)
helios fuji-settings device-info # dump advertised PTP operations and properties
helios fuji-settings sweep-props # probe the PTP property space, show what is writable
helios fuji-settings test-writable # empirically test which PTP properties accept a write
helios fuji-recipes             # film recipe management, see below
```

## Import

`import camera` and `import filesystem` both process files in three passes,
in this order: JPEGs, then videos (`.MOV`), then raws (`.RAF`). Same content
dedup (by md5) applies to all three. If a camera connection drops mid-import,
the earlier, more important passes are already downloaded and imported
rather than stranded.

Everything lands together in `<library>/_provisional/YYYY/YYYY_MM_DD/`, one
flat date tree regardless of type: a JPEG, its RAF, and any MOVs from the
same session sit side by side.

JPEG timestamps come from Pillow's EXIF reader. RAF and MOV timestamps come
from `exiftool` instead (Pillow can't open either format); the nix package
puts `exiftool` on `PATH` for the wrapped binary, so nothing extra to
install.

The dedup database defaults to `<library>/helios.db`. Losing it (or pointing
`HELIOS_DB_PATH` somewhere empty) doesn't lose photos, but it does mean the
next import re-copies everything already in the library, landing as
`_md5suffix` duplicates next to the originals.

Raws are a local edit cache, not archival: `backup-photos-to-dr` mirrors the
whole library to tiger, but excludes `.RAF` from the S3 disaster-recovery
copy on purpose (see `tf/photos-backup.tf`). Culling a JPEG from
`_provisional/` should take its RAF sibling with it; that's a cull-tool
concern, not something helios does automatically.

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

Backups are cheap and read-only, so take one before writing recipes:

```
helios fuji-settings backup
```

That writes `MODEL-DATE.bak` into `<library>/settings/backups/`. Writing one back
with `helios fuji-settings restore` works on the X-T5, so a backup is a real
restore point for the whole camera, not just a record. To undo a bad recipe write
you can restore a known-good `.bak`, or re-push your recipe files with
`helios fuji-recipes restore`, whichever is handier.

Whole-camera backups default into the photo library (`~/photos`, or wherever
`HELIOS_LIBRARY_PATH` points) under `settings/backups/`. Recipe files default there too
under `settings/recipes/`, unless `HELIOS_RECIPE_DIR` is set - see "Recipe files" below.

### Inspecting a backup

The `.bak` blob carries more per-slot state than the live PTP recipe path can
reach. `inspect` decodes a backup file offline (no camera): the image-quality
look (film sim, dynamic range, color, sharpness, tones, color chrome, grain),
per-slot auto-ISO, and the per-slot menu settings (image quality, AF mode,
shutter type, self-timer, and more).

```
helios fuji-settings inspect MODEL-DATE.bak       # per-slot recipe + auto-ISO
helios fuji-settings inspect MODEL-DATE.bak --raw  # also dump each record hex
```

`diff` and `correlate` are the reverse-engineering tools. `diff` shows which
bytes a setting change moved; `correlate` locates blob offsets automatically by
matching a backup against recipes whose values are already known (no camera
needed once you have one varied backup):

```
helios fuji-settings diff new.bak --slots 1,2      # slot C1 vs C2 in one file
helios fuji-settings diff old.bak new.bak          # same slot across two backups
helios fuji-settings correlate new.bak --recipes DIR  # match known recipes to offsets
```

To map a field not yet decoded: change one known setting on the camera, take a
fresh backup, `diff` it against the previous one; the differing bytes are that
setting's footprint. The verified layout, encodings, and what is still unknown
live in `FUJI_BLOB_FORMAT.md`. Only the X-T5 format is decoded; other models need
`--force` and the offsets may be wrong.

`edit` rewrites slots in a backup file offline and recomputes the whole-file
checksum, writing a new file. Three modes:

```
helios fuji-settings edit new.bak --slot 7 --name "My Slot"   # rename a slot
helios fuji-settings edit new.bak --slot 7 --recipe c7.yaml   # look + auto-ISO + menu settings
helios fuji-settings edit new.bak --recipe-dir DIR            # configure all seven
```

`--recipe` writes one slot's image-quality look, auto-ISO, and per-slot menu
settings from a recipe file; `--recipe-dir` does all seven `c1..c7` files in one
pass. This path reaches per-slot fields the live PTP `fuji-recipes` path cannot
(auto-ISO and the menu settings). The menu-field encodings come from single
controlled diffs, so validate a restore against a fresh camera backup. What each
field maps to and how far it is
trusted lives in `FUJI_WRITE_SURFACE.md`.

Push the modified blob back with `helios fuji-settings restore`. Editing the slot
name and restoring it is confirmed on the X-T5: the new name shows in the camera
menu, and only the whole-file checksum needs recomputing (no per-record checksum
stands in the way). Editing sharpness and auto-ISO then restoring is confirmed on
the X-T5 too: both read back correctly after a power cycle. The rest of the look
encoders reproduce every sample backup byte-for-byte and sit in the same record
region, so they should apply the same way. Take a fresh backup first so you can
always put it back.

### Usage

```
# see what is on the camera
helios fuji-recipes list
helios fuji-recipes list --dump-raw   # raw property values, for debugging

# camera slots -> files (c1-<name>.yaml .. c7-<name>.yaml)
helios fuji-recipes backup                # into <library>/settings/recipes
helios fuji-recipes backup --dir ./recipes --slots 1,3

# file -> camera slot
helios fuji-recipes restore kodachrome-64.yaml --slot 3

# whole directory -> camera, mapping c1-*.yaml to C1 and so on
helios fuji-recipes restore               # from <library>/settings/recipes
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

Imported recipes land in the library without a slot prefix. Directory restore
only pushes `c1-` to `c7-` prefixed files and skips the rest, so rename a
recipe to `c3-kodachrome-64.yaml` (or restore it by file with `--slot 3`) to
assign it a slot.

### Recipe files

One YAML file per recipe. Everything is hand-editable. The version-controlled copy
lives in this repo at `fuji-recipes/`. `HELIOS_RECIPE_DIR` points every command's
recipe-dir default there instead of `<library>/settings/recipes` (dino sets it in
`nix/hosts/dino/configuration.nix`), so `helios fuji-recipes backup` writes straight
into the repo and `git diff fuji-recipes/` shows what changed on the camera since the
last commit. Only the recipe dir moves; `HELIOS_LIBRARY_PATH` still governs
whole-camera backups and the dedup db. `--dir` / `--recipe-dir` / `--output` override
it per command, same as any other helios path.

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
- **dynamic_range**: 100, 200, 400, or Auto. The camera stores Auto as
  0xFFFF; confirmed on the X-T5 against a slot programmed from a published
  DR-Auto recipe.
- **grain**: Off, Weak/Small, Strong/Small, Weak/Large, Strong/Large. The
  X-T5 stores Off as raw value 6, not the 1 filmkit inferred; we read both
  as Off and write 6.
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
- **Per-slot menu settings**: the custom-bank EDIT/CHECK menu items (AF/MF,
  drive, shutter, image quality) that only the blob (`.dat`) restore path writes.
  `fuji-recipes restore` (PTP) cannot reach them and warns when it sees one.
  Each byte was located by a controlled diff; see `FUJI_BLOB_FORMAT.md`.
  - **Swept enums** take menu names: `image_quality` (fine / normal / fine+raw /
    normal+raw / raw), `af_mode` (single-point / zone / wide-tracking / all),
    `shutter_type` (mechanical / electronic / mech+elec / electronic-front-curtain
    / efc+mech / efc+mech+elec), `self_timer` (off / 2s / 10s), `d_range_priority`
    (off / weak / strong / auto), `afc_custom` (set1..set5), `image_size` (l / m /
    s), `aspect_ratio` (3:2 / 16:9 / 1:1), `raw_recording` (uncompressed /
    lossless-compressed / compressed), `num_focus_points` (117 / 425), `instant_af`
    (af-s / af-c).
  - **`detection`** is one key for the mutually-exclusive face/eye and subject
    detection modes (they share record bytes): `off`, `face`, `face+eye-auto`,
    `face+eye-right`, `face+eye-left`, or `subject-<type>` where type is animal,
    bird, automobile, motorcycle, airplane, or train.
  - **Confirmed toggles** take menu names too: `af_point_display` (on/off),
    `interlock_spot_ae` (on/off), `release_priority_afs` / `release_priority_afc`
    (release/focus), `flicker_reduction` (first-frame/all-frames), `lmo` (on/off),
    `pre_af` (on/off), and `af_mf` (on/off, a preamble byte). `grain` also accepts
    `Off` now.
  - **Unconfirmed toggles** were mapped from a single diff, so their direction is
    unknown and they take the raw byte `0` or `1` (read it back with
    `fuji-settings inspect`): `dof_scale`, `self_timer_lamp`, `save_self_timer`,
    `interval_priority`, `preshot_es`, `sports_finder`.
  - The truncated last slot (C7) can't hold the trailer-flag byte some of these
    use, so a flagged field (e.g. `d_range_priority`) aimed at C7 is refused; set
    those on C1-C6 or on the camera. `detection` is all body bytes, so it works on
    C7 too.

### Limitations

- **Two write paths, different reach.** The live PTP path (`fuji-recipes
restore`) writes the image-quality look through the property view
  (`0xD18E-0xD1A5`): film sim, WB, tone, grain, clarity, and so on. ISO and
  exposure compensation are not among those properties, so `import` keeps those
  lines as comments. A custom slot stores more than the PTP view exposes: its own
  **auto-ISO** configuration (three AUTO1/2/3 banks) and a set of **per-slot menu
  settings** (image quality, AF mode, shutter type, and more), both of which live
  in the whole-camera backup. The blob write path reaches them: `helios
fuji-settings edit` (and `--recipe-dir`) rewrites slots from recipe files,
  recomputes the whole-file checksum, and `helios fuji-settings restore` applies
  it on the X-T5, committing every slot in one pass, confirmed on the camera. The
  look and auto-ISO round trips are confirmed; the menu-field encodings come from
  single controlled diffs, so validate a restore against a fresh backup. Slot
  **names** are the one restriction: the camera caps
  the total length of all seven names (mid-90s of characters), so a set of long
  recipe names may not all fit in one restore (see FUJI_WRITE_SURFACE.md,
  "Restoring many slots at once").
- **Clarity is not written over USB.** Writes to the clarity property
  (`0xD1A2`) on the X-T5 come back `PTP 0x201C`, which is the standard PTP
  `InvalidDevicePropValue`: the property is supported (reads work) but the value
  is rejected in the camera's current state. This is not a hard protocol limit:
  filmkit writes clarity fine on the X100VI, so it is an X-T5 state/firmware
  condition we have not yet pinned down (a USB capture of X RAW Studio writing
  clarity to an X-T5 would settle it). `restore` warns and leaves clarity
  untouched, so set it by hand in IMAGE QUALITY SETTING > CLARITY and resave the
  slot (needs JPEG; HEIF greys the menu out). Recipe files keep the value for
  reference.
- **Stills slots only.** The X-T5 has a separate C1-C7 bank for movie mode,
  but the protocol for it is unmapped. Video settings are still covered by
  the whole-blob backup.
- **Encodings confirmed on the X100VI and X-T5.** Reverse engineered from
  X100VI captures (filmkit), then verified against a real X-T5, which is
  where the DR-Auto, grain Off, and clarity quirks above came from. Other
  X-Processor 5 bodies should behave the same. Rejected writes come back as
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
