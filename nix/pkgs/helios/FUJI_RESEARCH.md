# Fujifilm settings reverse-engineering: research notes and sources

Background research behind `fuji_recipes.py`, `fuji_settings.py`, and
`fuji_backup.py`. This is the annotated bibliography and the key conclusions;
`FUJI_BLOB_FORMAT.md` holds the concrete backup-blob layout, and the code holds
the working encodings. Written 2026-07 against a real X-T5.

## Ground rule

The original recipe code was reverse engineered "just enough to get it
working," so its property IDs, encodings, and limitations notes were treated
here as **unverified working notes, not truth**, and re-checked against primary
sources and against the camera's own behavior. Where a claim could not be
sourced or reproduced, it is marked as such. Direct observation of the camera
outranks the manual (see custom-setting scope below).

## Two PTP property views of a custom slot

A Fujifilm body in USB RAW CONV./BACKUP RESTORE mode exposes custom-slot data
as PTP device properties, but there are two distinct groups, with different
authoritative sources:

### 1. The preset/recipe block, `0xD18C-0xD1A5`

This is what `fuji_recipes.py` reads/writes: image size/quality, film sim,
dynamic range, grain, color chrome, WB, tones, color, sharpness, high-ISO NR,
clarity, long-exposure NR, color space. Authoritative source is **filmkit**
(reverse engineered from Wireshark captures of an X100VI talking to Fujifilm X
RAW Studio); our IDs and names match it one-for-one.

- filmkit, pinned commit `9e3bbcf858b1`:
  <https://github.com/eggricesoy/filmkit/tree/9e3bbcf858b1>
  - property + opcode ids: `src/ptp/constants.ts`
  - encodings + conditionals: `src/profile/preset-translate.ts`
  - write sequence: `src/ptp/session.ts`
  - the 625-byte `0xD185` X RAW Studio profile: `src/profile/d185.ts`

Key facts confirmed from filmkit's source (not just its README):

- **Preset save is a bare sequence of `SetDevicePropValue` writes, no
  begin/commit/apply opcode.** `0xD18C` (slot selector) is the only "which
  preset" state. `StartRawConversion 0xD183` / `RawConvProfile 0xD185` belong to
  a separate RAW-conversion flow, not preset save.
- Encodings: tones/color/sharpness/clarity and mono WC/MG are signed 16-bit
  `x10`; `0x8000` = "use default" sentinel for tones; high-ISO NR uses a
  proprietary (non-linear, non-x10) table; dynamic range is stored as the raw
  percentage; grain is packed (strength low byte, size high byte); WB color temp
  is only accepted immediately after the WB mode and only in ColorTemp mode;
  Color Chrome / FX-Blue / Smooth-Skin are 1-indexed.
- **`0xD191` and `0xD1A5` are unknown even to filmkit** (we carry them as
  passthrough).
- filmkit treats clarity (`0xD1A2`) as an ordinary `x10` value with **no
  special handling**, and it works on the X100VI. See clarity below.

### 2. Global device properties (ISO, AF, drive, metering)

These are separate from the preset block and are named authoritatively by
libgphoto2 / libfuji, NOT by filmkit (filmkit's non-preset codes conflict with
these and are unreliable):

- libgphoto2 `camlibs/ptp2/ptp.h` (standard PTP response codes + `PTP_DPC_FUJI_*`):
  <https://github.com/gphoto/libgphoto2/blob/master/camlibs/ptp2/ptp.h>
- libfuji `lib/fujiptp.h` (mirrors the `PTP_DPC_FUJI_*` names):
  <https://github.com/petabyt/libfuji/blob/master/lib/fujiptp.h>
- Real-camera dumps: e.g. `camlibs/ptp2/cameras/fuji-xt2.txt`.

Names elsewhere list ISO `0xD02A ExposureIndex`, an auto-ISO triplet
`0xD115-D117 ISOAutoSetting1/2/3`, drive `0xD201 ReleaseMode`, AF
`0xD206-D209`, metering `0xD17C FocusMeteringMode`. **But a direct sweep of the
real X-T5 (below) advertises none of these** - not ISO, not auto-ISO, not
drive/AF/metering - so on this body the only writable "global" props are the
live image-quality mirror (`0xD001` etc.). **There is no `PTP_DPC_FUJI_Clarity`**
anywhere; clarity exists only as preset prop `0xD1A2` or field [27] of the
`0xD185` profile.

## Clarity: why the X-T5 rejects the write

- The X-T5 returns `PTP 0x201C` for the clarity `0xD1A2` write **during a recipe
  restore**; reads work. But a **standalone same-value write to `0xD1A2` is
  accepted** (`test-writable`), so the rejection is not unconditional - it
  depends on the state left by earlier writes in the restore batch.
- **`0x201C` = `PTP_RC_InvalidDevicePropValue`**, a standard PTP/ISO 15740 code
  (libgphoto2 `ptp.h`): the property is supported but the value is rejected in
  the camera's current state. Distinct from `0x201B` (format/width) and `0x200A`
  (prop unsupported). The sweep confirmed `0x201C` is the camera's generic "not
  valid right now" - the same code gates mono_wc/mg and wb_color_temp when the
  slot's film sim / WB mode do not allow them.
- filmkit writes clarity fine on the X100VI, so this is an **X-T5
  state/firmware condition, not a protocol wall.**
- Clarity is documented by Fujifilm as heavy post-capture processing ("increases
  the time needed to save each shot"), auto-disabled in burst/HDR and for HEIF.
  X-T5 manual, IMAGE QUALITY SETTING:
  <https://fujifilm-dsc.com/en/manual/x-t5/menu_shooting/image_quality_setting/>
- No primary source documents a PTP clarity rejection specifically; our X-T5
  observation is the data point. Deferred fix paths: capture X RAW Studio
  writing clarity to an X-T5 over USB and replicate; or set it via a blob
  restore (both the checksum and the restore transport are now solved, so this
  path is open if clarity turns out to live in the blob). Current behavior: warn
  and skip.

## Custom-setting scope: manual vs. observation

- The X-T5 manual lists a C1-C7 custom setting as holding the IMAGE QUALITY
  SETTING menu items only; AF lives in AF/MF SETTING and ISO in SHOOTING
  SETTING. The X-T5 has no mode-dial custom banks (unlike the X-H2/X-H2S, whose
  mode-dial C1-C7 do store AF/drive/ISO).
- **But direct observation wins, and the scope is far wider than the manual
  says.** A controlled per-slot diff campaign (change one EDIT/CHECK item per
  slot, re-backup, `diff --whole-file`) walked the whole menu on a real X-T5. A
  custom bank stores not just the image-quality look but auto-ISO, most of the
  AF/MF menu (AF mode, AF-C custom, pre-AF, face/eye and subject detection,
  number of focus points, instant AF, release/focus priority, AF point display,
  DoF scale, interlock spot AE) and much of the Camera menu (shutter type,
  self-timer and its lamp/save sub-settings, sports finder, pre-shot ES, interval
  priority, flicker reduction). See `FUJI_BLOB_FORMAT.md`, "Per-slot AF/drive/
  shooting fields", for the byte map.
- **The exceptions (menu items NOT stored per bank):** color space, AF
  illuminator, wrap focus point, MF assist, IS mode, focus check, touch screen
  mode are global/live (no per-slot byte moves). Drive mode is global at file
  `0x700`. Interval timer shooting is greyed and cannot be saved per bank. So the
  manual's "image quality only" is wrong in one direction (most AF/drive settings
  are per-slot) and these few are the genuine not-per-slot cases.
- Whether auto-ISO is reachable as a PTP property at all is answered by the sweep
  below: it is not.

## PTP writability sweep on the real X-T5 (2026-07)

`helios fuji-settings sweep-props` and `test-writable` probe the device-property
space directly. On an X-T5 in USB RAW CONV./BACKUP RESTORE mode:

- **GetDevicePropDesc (0x1014) is unsupported for the vendor props.** Only the
  two generic MTP props `0xD406`/`0xD407` return a descriptor, so the declared
  read/write flag is unavailable. Writability had to be tested empirically, by
  writing each property's current value back to itself (`test-writable`).
- **59 vendor properties advertised, 43 accept a write**, in two parallel sets:
  - the per-slot preset/recipe block `0xD18E-0xD1A5` (what `fuji-recipes` writes);
  - a **global "live settings" mirror** the recipe path ignores: `0xD001`
    FilmSimulation, `0xD007` DRangeMode, `0xD008` ColorMode, `0xD00A` ColorSpace,
    `0xD00B/C` WhitebalanceTune1/2, `0xD017` ColorTemperature, `0xD018` Quality,
    `0xD01C` NoiseReduction, `0xD029` Shadowing, `0xD02E` WideDynamicRange,
    `0xD104` BlackImageTone, `0xD320` HighLightTone, `0xD321` ShadowTone,
    `0xD34D` LMOMode (names from libfuji `lib/fujiptp.h`). These write the
    camera's current state, not a stored slot.
- **`0x201C` (InvalidDevicePropValue) means "not valid in the current state,"
  not read-only.** The rejects were readouts/state-gated: `0xD20B` DeviceName,
  `0xD212` CurrentState, `0xD36A/B` BatteryInfo, `0xD023` GrainEffect, and the
  recipe conditionals `mono_wc`/`mono_mg` (slot is not monochrome) and
  `wb_color_temp` (WB is not Color Temp).
- **Auto-ISO is absent from the PTP property space.** No `0xD115-D117`
  ISOAutoSetting, nor any auto-ISO-shaped property, is advertised or responds
  anywhere in a full `0x0000-0xFFFF` sweep. So per-slot auto-ISO **cannot** be
  written over PTP; the whole-camera blob is the only path. This is the crux for
  writing a complete custom-settings slot from a file: the image-quality look
  goes over PTP today, and auto-ISO (and any other blob-only per-slot state) goes
  through the blob-edit path, whose checksum and restore transport are both now
  solved (see below and `FUJI_BLOB_FORMAT.md`).
- **Clarity `0xD1A2` accepted a standalone same-value write**, contradicting the
  earlier "the X-T5 rejects clarity" note. The rejection seen during
  `fuji-recipes restore` is therefore likely sequence-dependent (state left by an
  earlier write in the batch), not a hard limit - a lead worth chasing.

Source for the property names: libfuji `lib/fujiptp.h`
<https://github.com/petabyt/libfuji/blob/master/lib/fujiptp.h>.

## The whole-camera backup blob

Details, offsets, and encodings are in `FUJI_BLOB_FORMAT.md`. Summary: the blob
carries the full per-slot state the PTP preset block misses (auto-ISO decoded and
verified). The image-quality look was also located in blob offsets by
known-plaintext correlation against known recipes (`helios fuji-settings
correlate`): film sim, dynamic range, color, sharpness, highlight/shadow tone,
color chrome (+FX blue), and grain, each with its own encoding distinct from the
PTP codes. The whole-file checksum at `+0xE8` is **solved** (a 16-bit additive
byte-sum over `[0xA8, EOF)` with two skipped ranges and a `+0xF936` bias,
recovered from the X Acquire SDK and verified on five captures; `helios
fuji-settings edit` recomputes it). The field at `+0xE8` is a u32 whose high half
is a save counter; the sum skips all four bytes, and getting that wrong (summing a
nonzero high half) was a one-count error that failed the first edited restore. The
**restore transport** is now solved too: restore is plain PTP
`SendObjectInfo`/`SendObject`, and one `PTP 0x200F` denial was a 12-byte-too-long
ObjectInfo (helios padded to 1088 where the camera wants 1076). An edited blob
now writes back and **applies**: editing the C7 slot name and restoring it showed
on the camera, with no per-record checksum needed (see `FUJI_BLOB_FORMAT.md`).

The transport is solved and a restore commits **every slot's look in one shot**,
the same as X Acquire, confirmed 2026-07-16 on the X-T5 (a one-byte-per-slot
seven-slot edit and the full look of all seven recipes both applied). The catch is
slot **names**, not a slot count.

The earlier "four-slot cap" framing is wrong. Look-field changes have no cap (seven
at once is fine). What is capped is **renames**, by a camera-side **total
slot-name-length budget**: the restore path validates the sum of the seven names
and denies with `0x200F` (data phase) when it overflows. On this X-T5 the seven
recipe names summed to 105 chars and did not fit (six committed, the seventh
rejected); the ceiling is in the mid-90s of total characters and is sensitive to how
names are applied, consistent with a limited/fragmenting name store. Two aggravators:
the post-name tag at `+0x1E9` (`CC24`/`CC60` on swept slots) must be cleared on
rename or the camera rejects two-plus tagged renames (helios now clears it in
`patch_slot_name`); and `0x200F` is overloaded with the not-clean-state denial, so
restore clean and first. Intermediate guesses that were wrong and are recorded so
they are not retried: the `+0xE8` high half is one file-global u16 save counter (not
per-slot tracking), and there is no per-record integrity token, `fuji-settings
commit-probe` showed the camera re-stamps nothing inside the record, only a global
lens/state block (`0x7aac..0x7b24`) it accepts stale. See `FUJI_WRITE_SURFACE.md`,
"Restoring many slots at once."

## Prior-art landscape (annotated)

### Backup-blob format: essentially undocumented

A GitHub code search for the `FUJIFILMX-BACKUP` magic returns **zero** results
(2026-07). Our RE goes further than anything public.

- **libfuji** transports the blob only (PTP object handle 0, format `0x5000`,
  `uint32` length prefix, "too big" guard at 100000 bytes), no content parsing.
  Authoritative for the transfer path, and matches `fuji_settings.py`:
  <https://github.com/petabyt/libfuji/blob/master/lib/fuji_usb.c>
- **petabyt/fp** parses the X RAW Studio profile (`FP1/2/3`, the `0xD185`
  structure), a different format unrelated to the backup blob:
  <https://github.com/petabyt/fp>
- **DPReview GFX100s "backup file decode and restore.dat" thread** is the one
  useful breadcrumb: a dev decoded the `.dat`, edited settings, but stalled on
  recomputing a whole-file CRC located near bytes `0xE4/0xE5`, validated on
  restore. Closed source (Java then Delphi), no spec published:
  <https://www.dpreview.com/forums/threads/fuji-gfx100s-backup-file-decode-and-restore-dat.4577633/>
- **DPReview X-T2 "camera settings file display" thread** ("Macro" Java jar):
  decodes an X-T2 `.DAT` to HTML, enforces model-specific file size, but ships
  no source or offset map. Confirmed display-only (no USB, restore, or checksum
  code) by decompiling the jar:
  <https://www.dpreview.com/forums/threads/fujifilm-x-t2-camera-settings-file-display.4295462/>
- **FUJIFILM X Acquire** (the official Mac/Windows backup/restore app; Windows
  v1.29.0 statically analyzed on Linux, extracted with `unshield`). `XGFXAPI.dll`
  exports `XSDK_GetBackupSettings`/`XSDK_SetBackupSettings` (class
  `CCameraCommandBackupSettings`); `FTLPTP.dll` is a generic PTP transport with no
  Fuji vendor opcodes. The whole-file checksum algorithm came from disassembling
  this SDK; the exact restore opcode sequence (plain `SendObjectInfo`/`SendObject`
  with a 1076-byte ObjectInfo) came from a usbmon capture of the app restoring to
  a live X-T5. Not open source; recovered for interoperability.

### PTP protocol and firmware RE (broader ecosystem)

- filmkit (preset block; see above): <https://github.com/eggricesoy/filmkit>
- libgphoto2 (canonical `PTP_DPC_FUJI_*`):
  <https://github.com/gphoto/libgphoto2>
- petabyt/libfuji and petabyt/libpict (formerly "camlib"):
  <https://github.com/petabyt/libfuji>, <https://github.com/petabyt/libpict>
- petabyt/fudge / fujiapp (Camera Connect reimplementation, WiFi PTP), and the
  writeup: <https://github.com/petabyt/fudge>, <https://danielc.dev/blog/fudge1/>
- hkr/fuji-cam-wifi-tool (original WiFi remote-control RE):
  <https://github.com/hkr/fuji-cam-wifi-tool>
- fujihack (firmware-level RE): <https://github.com/fujihack/fujihack>,
  <https://wiki.fujihack.org>

## How this was researched

Three parallel web/GitHub research agents (filmkit deep-dive; libgphoto2/libfuji
property tables + the `0x201C` meaning; X-T5 manual + clarity), a fourth on the
backup-blob format specifically, `gh search code` for the blob magic, and
controlled-backup diffing on the real camera (change one known setting,
re-backup, `helios fuji-settings diff`). The controlled-diff method is how the
auto-ISO block was decoded and is how the rest of the blob should be extended;
see `FUJI_BLOB_FORMAT.md`.

## Open questions / deferred

The goal these feed is **writing a complete custom-settings slot from a source
file.** The image-quality look is writable over PTP today (`fuji-recipes
restore`), but auto-ISO - and anything else that lives only in the blob - is not
(the sweep proved auto-ISO has no PTP property). So a complete file-driven write
needs the blob-edit path, and that path now works end to end: `edit`/`--recipe-dir`
rewrites slots and `restore` commits every slot's look at once on the X-T5 (image-quality
look, wb-shift, high-ISO-NR, sharpness, and auto-ISO all confirmed committing). The
whole-file checksum is the only integrity gate on the look, and it is solved. The one
restore-time cap is on slot _names_: the camera limits the total length of all seven
names together (mid-90s of characters on this body), so a set of long recipe names may
not all fit in one pass even though their looks do. What is left is broadening the set
of _editable_ fields. In priority order:

- **A per-record sub-checksum does not gate a slot edit (resolved).** The concern
  was that the record trailer `+0x37C..0x3FF` or the u16 near `+0x7B24` might be
  per-record checks an edit would invalidate. The confirmed name edit disproves
  it: the change went in with the trailer untouched and only the global `+0xE8`
  sum recomputed, and the camera applied it. Those trailer bytes that move +/-1
  with content are settings, not an integrity check.
- **Extend `edit` beyond the slot name.** Auto-ISO and the packed recipe bytes
  live in the same record region and are covered by the same global checksum, so
  they should apply the same way, but only the name edit is hardware-confirmed.
  Wire `--auto-iso` into `edit` and confirm one field on the camera before
  trusting the rest.
- Blob offsets for the remaining recipe fields: white balance mode, WB shift R/B,
  `wb_color_temp`, high-ISO NR, and clarity (all vary across slots but match no
  single byte/word; likely multi-byte or a different encoding).
- Whether the clarity rejection during `fuji-recipes restore` is caused by the
  write order (a standalone same-value write is accepted). If so, reordering or
  isolating the clarity write could unblock it without the blob path.
- The full min-shutter menu ladder (five points confirmed so far).
- The blob film-sim code table is partial (four sims confirmed); grain "Off" is
  unconfirmed.
