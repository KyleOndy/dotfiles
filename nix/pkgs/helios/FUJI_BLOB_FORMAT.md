# Fujifilm whole-camera backup blob format

Reverse-engineered notes on the `.DAT`/`.bak` file the camera writes in USB
RAW CONV./BACKUP RESTORE mode (the same object `fuji_settings.py` transfers as
PTP object handle 0, format `0x5000`). `helios fuji-settings inspect` and
`helios fuji-settings diff` parse the file described here. For the field-oriented
view of what `helios fuji-settings edit` can write back, see
[FUJI_WRITE_SURFACE.md](FUJI_WRITE_SURFACE.md).

**Status: partial, X-T5 only.** Everything below was derived by diffing
controlled X-T5 captures (change one known setting on the camera, re-backup,
diff). Fields are tagged **verified** (reproduced from a controlled capture),
**inferred** (consistent but not isolated), or **unknown**. Offsets and
encodings are confirmed on the X-T5 (X-Processor 5) only.

## Why this exists (and how it differs from the PTP recipe view)

`fuji_recipes.py` reads/writes the per-slot image-quality look through PTP
device properties `0xD18E-0xD1A5`. Those 24 properties are _not_ everything a
custom slot stores. The whole-camera backup blob carries the full per-slot
state, including things the PTP properties never expose, most notably the
per-slot **auto-ISO** configuration. So the blob, not the PTP property set, is
the source of truth for "what a slot holds."

## Prior art (essentially none)

No public spec, parser, or checksum algorithm documents this blob. A GitHub
code search for the `FUJIFILMX-BACKUP` magic returns nothing (2026-07). What
exists:

- **libfuji** (`petabyt/libfuji`, `lib/fuji_usb.c`) only _transports_ the blob:
  object handle 0, format `0x5000`, a `uint32` length prefix, and a
  "too big" guard at 100000 bytes. It does not parse the contents. This is the
  authoritative reference for the transfer, and matches `fuji_settings.py`.
  <https://github.com/petabyt/libfuji/blob/master/lib/fuji_usb.c>
- **petabyt/fp** parses the X RAW Studio profile (`FP1/2/3`, the `0xD185`
  625-byte structure) - a _different_ format, unrelated to this blob.
- Closed-source hobbyist viewers exist (a Java `.jar` for the X-T2 by "Macro";
  a Delphi rewrite discussed in a GFX100s thread) but never published the
  layout. The GFX100s thread is the one useful breadcrumb: it reports a
  whole-file CRC near bytes **`0xE4/0xE5`** that the camera validates on
  restore and recomputes when settings change - see the checksum note below.
  <https://www.dpreview.com/forums/threads/fuji-gfx100s-backup-file-decode-and-restore-dat.4577633/>

Our RE (header + per-slot records + the 9-byte auto-ISO block + the per-record
trailing field) already goes further than anything public.

## File header (verified)

| Offset | Bytes          | Meaning                        |
| ------ | -------------- | ------------------------------ |
| `0x00` | 16             | ASCII magic `FUJIFILMX-BACKUP` |
| `0x10` | 4              | ASCII version, `0100`          |
| `0x14` | NUL-term ASCII | model, e.g. `X-T5`             |
| `0x34` | NUL-term ASCII | camera serial number           |

Around `0x90` there is a table of little-endian `u32` values describing the
payload: `0x098` holds `0xA8` (the payload start) and `0x0A0` holds
`filesize - 0xA8` (its length), so the payload region is `[0xA8, EOF)`. Within
the `0xB8`..`0xEC` cluster, `0x0E8` holds the **whole-file checksum** (the low
half of a u32 whose high half is a small counter, solved below), `0x0E4` is a
constant `0x0243`, and `0x0CC`/`0x0D0` are volatile counters (they differ between
same-day captures yet repeat across unrelated ones, so they are not content
hashes). A separate u16 at `0x584` also ticks on each save (see the checksum
note). The parser does not rely on any of this; it locates the slot records
geometrically instead (see below).

## Per-slot custom-setting records (verified geometry)

The C1-C7 custom settings are seven fixed-size records at the tail of the file:

- **`0x400` (1024) bytes each, `0x400`-aligned.** On the sample X-T5 backups
  the first record starts at `0x7C00` and they run C1..C7 to `0x9400`. The file
  ends inside the last record (trailing padding trimmed).
- The parser finds them as the last seven `0x400`-aligned blocks and validates
  that the name fields are readable. It does not hardcode `0x7C00`.

All record-field offsets below are **relative to the start of a record.**

| Rel. offset                        | Len    | Field                                                                                                    | Status       |
| ---------------------------------- | ------ | -------------------------------------------------------------------------------------------------------- | ------------ |
| `0x006`                            | 1      | WB shift R: `value = 9 - raw`, integer -9..+9                                                            | **verified** |
| `0x008`                            | 1      | WB shift B: `value = 9 - raw`, integer -9..+9                                                            | **verified** |
| `0x022`                            | 1      | high-ISO NR: `value = raw - 4`, integer -4..+4 (linear, unlike the PTP table)                            | **verified** |
| `0x025`                            | 1      | clarity: `value = raw - 6`, integer -5..+5 (only applies when the slot is JPEG)                          | **verified** |
| `0x04C`..`0x06B`                   | packed | image-quality "recipe" struct (see below)                                                                | **verified** |
| `0x092`                            | 9      | auto-ISO block (see below)                                                                               | **verified** |
| `0x0EB`                            | 1      | image format flag: HEIF=`0x01`, JPEG=`0x00`                                                              | **verified** |
| `0x1CF`                            | ≤26    | slot name, NUL-terminated ASCII                                                                          | **verified** |
| `0x1E9`                            | 4      | ASCII tag (`"CC24"`, `"CC60"`, ..., `0` when empty); **not** a checksum                                  | **verified** |
| `0x3AE`..`0x3D3`                   | flags  | per-slot AF/IQ on/off flags (see "Per-slot AF/drive/shooting fields"); overlaps the next slot's preamble | **verified** |
| `0x02A`, `0x064`, `0x066`, `0x090` | 1 each | move with edits (bank-select or dirty flags); still not decoded                                          | **unknown**  |

## Packed recipe struct (verified)

The per-slot image-quality look sits in a compact single-byte run at
`+0x4C`..`+0x6A`. It was located offline by known-plaintext correlation: a backup
whose seven slots held seven recipes with known values, matched byte-for-byte
against the saved recipe files (`helios fuji-settings correlate` automates this).
Every encoding below reproduces all seven sample slots exactly. **The blob uses
its own codes, distinct from the PTP recipe property codes** in `fuji_recipes.py`.

| Rel offset | Field                | Encoding                                                                     |
| ---------- | -------------------- | ---------------------------------------------------------------------------- |
| `+0x4C`    | film simulation      | own code table, all 20 mapped (Provia=`0x01` .. Reala Ace=`0x19`, with gaps) |
| `+0x58`    | mono MG              | `value = raw - 18`, integer -9..+9 (mono sims only)                          |
| `+0x5A`    | mono WC              | `value = raw - 18`, integer -9..+9 (mono sims only)                          |
| `+0x5C`    | dynamic range        | index: Auto=`0`, 100=`1`, 200=`2`, 400=`3` (all X-T5-verified)               |
| `+0x5F`    | color / chroma       | `value = 7 - raw`                                                            |
| `+0x61`    | sharpness            | `value = 4 - raw`                                                            |
| `+0x63`    | highlight tone       | `value = -2 + 0.5 * raw` (0.5 steps)                                         |
| `+0x65`    | shadow tone          | `value = -2 + 0.5 * raw`                                                     |
| `+0x67`    | color chrome effect  | `0`=Off, `1`=Weak, `2`=Strong                                                |
| `+0x68`    | color chrome FX blue | same strength encoding                                                       |
| `+0x69`    | grain roughness      | `0`=Strong, `1`=Weak, `2`=Off (3-value enum; Off ignores the size byte)      |
| `+0x6A`    | grain size           | `0`=Small, `1`=Large                                                         |
| `+0x6B`    | smooth skin          | `0`=Off, `1`=Weak, `2`=Strong                                                |

The film-sim table is complete (all 20 sims mapped by an X-T5 multi-slot sweep,
three backups covering the whole menu); an unexpected code still decodes to
`?0xNN`. Grain "Off" is code `2` in the roughness byte `+0x69` (X-T5 round 11),
not a separate gate, so grain is fully mapped now.
`+0x4F`..`0x5B` is constant across slots except the mono bytes at `+0x58`/`+0x5A`.

Now located too: white balance mode, `wb_color_temp`, and long-exposure NR, all
in the per-slot preamble (below), plus high-ISO NR (`+0x22`), mono WC/MG, smooth
skin, and clarity (`+0x25`) in the body. The PTP property IDs `0xD18E-0xD1A5`
remain the other, already-mapped view of the same look.

## Per-slot preamble (verified)

Three fields are not in the 0x400 record body. They sit in a small block just
_before_ each record start, at fixed distances back. Offsets below are measured
back from the record start; for slot 1 the block precedes the first record. All
three were located by an X-T5 multi-slot sweep and round trip byte-for-byte.

| Offset from start | Len | Field             | Encoding                                       |
| ----------------- | --- | ----------------- | ---------------------------------------------- |
| `-0x74`           | 2   | color temperature | u16 LE kelvin, used only when WB is Color Temp |
| `-0x48`           | 1   | long-exposure NR  | `1` = off, `0` = on (inverted from PTP)        |
| `-0x41`           | 1   | AF+MF             | `1` = on, `0` = off (X-T5 round 11)            |
| `-0x18`           | 1   | white balance     | mode code table (Auto=`0`, ..., Custom=`0x0B`) |

White-balance modes mapped: Auto=`0x00`, Auto White Priority=`0x01`, Auto
Ambience Priority=`0x02`, Daylight=`0x03`, Shade=`0x04`, Fluorescent
1/2/3=`0x05`/`0x06`/`0x07`, Incandescent=`0x08`, Underwater=`0x09`, Color
Temp=`0x0A`, Custom=`0x0B`. The three auto variants and Custom came from a
seven-slot sweep with four already-mapped modes as anchors. Only Custom 2/3 are
unconfirmed (one Custom slot mapped to `0x0B`; whether the other two take
`0x0C`/`0x0D` is untested). Unmapped codes decode as `?0xNN`. Image quality also
has a preamble byte at `-0x4C` (paired with body `+0x29`); the remaining AF/drive/
shooting settings turned out to live mostly in the record body, not the preamble
(see "Per-slot AF/drive/shooting fields").

## Auto-ISO block (verified)

Nine contiguous bytes at record `+0x92`, three banks (AUTO1/AUTO2/AUTO3), laid
out `[default x3 banks][max x3 banks][min-shutter x3 banks]`:

| Sub-offset | Bytes | Parameter                        |
| ---------- | ----- | -------------------------------- |
| `+0x92`    | 3     | default sensitivity, banks 1/2/3 |
| `+0x95`    | 3     | max sensitivity, banks 1/2/3     |
| `+0x98`    | 3     | min shutter, banks 1/2/3         |

Encodings, verified against a controlled backup that reproduced both a control
slot (125 / 6400 / AUTO on all banks) and a test slot (160/400 1/500,
640/3200 1/60, 1600/12800 1/8) exactly:

- **default sensitivity:** 1/3-stop index counting down from 12800.
  `index 0 = 12800 ... index 20 = 125`; value = `ISO_THIRDS[20 - index]`.
- **max sensitivity:** full-stop index counting down from 12800.
  `0 = 12800, 1 = 6400, 2 = 3200, ... 5 = 400`; value = `12800 >> index`.
- **min shutter:** menu-list index. Swept on the X-T5 (round 12) by setting the
  three AUTO1/2/3 banks to known speeds and reading them three per backup (the
  banks are stored per slot, and with "auto save changes" on the live edits land
  in the active slot only). The ladder runs in **1/3-stop steps through the fast
  region** then widens to **full stops once slow**:
  `4 = 1/500, 7 = 1/250, 8 = 1/200, 10 = 1/125, 13 = 1/60, 15 = 1/30, 16 = 1/15,
17 = 1/8, 18 = 1/4, 20 = 1s, 26 = AUTO`. The 1/3-stop gaps (5/6/9/11/12/14) and
  `19 = 1/2` are inferred and left out of `MIN_SHUTTER` so a write cannot pick an
  unverified index; the slow tail past 1s (21-25) is still unmeasured.

## Per-slot AF/drive/shooting fields (X-T5 controlled diffs)

A custom bank stores far more than the image-quality look. Setting one custom-bank
menu item on the camera, re-backing up, and running `helios fuji-settings diff
--whole-file` against the prior backup isolates each setting to its byte(s). The
whole EDIT/CHECK menu was walked this way (change one item per slot, one backup
per round). These are **single data points**: the locations are solid, but the
multi-value encodings (enums, durations) are not fully swept, so helios names the
bytes but does not decode them yet.

Body value bytes (offset relative to record start):

| Rel     | Field                                      | Rel      | Field                                    |
| ------- | ------------------------------------------ | -------- | ---------------------------------------- |
| `+0x26` | image size (L/M/S)                         | `+0xE8`  | interval priority mode                   |
| `+0x28` | aspect ratio (3:2/16:9/1:1)                | `+0xE9`  | raw recording                            |
| `+0x29` | image quality (+ preamble `-0x4C`)         | `+0xEC`  | flicker reduction                        |
| `+0x5E` | d-range priority (not the DR byte `+0x5C`) | `+0x103` | detection selector (face/eye vs subject) |
| `+0x6C` | AF mode (ALL flag at `+0x70`)              | `+0x106` | eye detection submode                    |
| `+0x84` | sports finder mode                         | `+0x109` | subject detection type                   |
| `+0x85` | pre-shot ES                                | `+0x10C` | detection selector (second byte)         |
| `+0x86` | self-timer                                 | `+0x10F` | AF point display                         |
| `+0x88` | save self-timer setting                    | `+0x110` | number of focus points                   |
| `+0x89` | self-timer lamp                            | `+0x111` | AF-C custom settings                     |
| `+0x8A` | pre-AF                                     | `+0x12B` | instant AF setting                       |
| `+0x8B` | release/focus priority AF-S                | `+0x12D` | depth-of-field scale                     |
| `+0x8C` | release/focus priority AF-C                | `+0x12E` | shutter type                             |
| `+0x9F` | interlock spot AE & focus area             |          |                                          |

Trailer flags block `+0x3AE..+0x3D3`: per-slot on/off bits, the enable half of
several of the settings above (`+0x3B2` face/eye, `+0x3B3` pre-AF, `+0x3B5` AF
point display, `+0x3B7` LMO (flag only), `+0x3B9` d-range priority, `+0x3BF`
subject detection, `+0x3D3` DoF scale). Two bytes here were mislabeled by early
diffs and are actually unidentified per-slot flags: `+0x3AE` (tagged shutter in
round 3, but round 8 shows shutter type at body `+0x12E` changing without it
moving) and `+0x3BD` (tagged AF+MF, but round 11 shows AF+MF toggling the preamble
byte `-0x41` in both directions while `+0x3BD` never moves and C2 sits stuck at
`6`). This is the region the earlier notes flagged as an undecoded "trailer": it
is per-slot settings, not a checksum, and it physically overlaps the next slot's
preamble (each record's last `PREAMBLE_SIZE` bytes are the following slot's WB
mode / color temp / long-exp NR / image-quality preamble).

**Not stored per bank (global or absent from the blob).** These appear in the
EDIT/CHECK menu but changing them moves no per-slot byte: **color space** (matches
the global PTP `0xD00A` mirror), **AF illuminator**, **wrap focus point**, **MF
assist**, **IS mode**, **focus check**, **touch screen mode**. **Drive mode** is
global at file offset `0x700` (a physical dial position). **Interval timer
shooting** is greyed in EDIT/CHECK and cannot be saved per bank.

**Couplings any editor must respect.** Face/eye and subject detection are mutually
exclusive, selected by the pair (`+0x103`, `+0x10C`): face/eye = `(1,1)`, subject =
`(0,0)`, off = `(0,1)`. The active family's parameter then lives in its own byte,
eye submode at `+0x106` (auto/right/left/off = `0/1/2/3`) or subject type at
`+0x109` (animal..train = `0..5`); the inactive family's byte carries a stale value
and is ignored. helios models the whole cluster as one `detection` recipe key so an
editor cannot request an impossible combination. Setting a slot to RAW-only zeroes
the JPEG sliders (e.g. sharpness `+0x61` goes to 0) and locks image size; re-enabling
JPEG does not restore the zeroed values.

**Writable through recipes (`fuji_backup.BLOB_SLOT_FIELDS`, `IMAGE_QUALITY_VALUES`,
`DETECTION_VALUES`, plus the preamble encoders).** These per-slot settings are
exposed as recipe keys and written by the blob restore path (`patch_slot_recipe`);
the live PTP `fuji-recipes` path cannot reach them.

Swept and labeled (X-T5 rounds 6-12), written by menu name:

| Field              | Byte(s)                             | Values (code)                                                                                 |
| ------------------ | ----------------------------------- | --------------------------------------------------------------------------------------------- |
| `image_quality`    | `+0x29` body, `-0x4C` pre           | fine `0/0`, normal `1/0`, fine+raw `2/2`, normal+raw `3/2`, raw `4/1`                         |
| `af_mode`          | `+0x6C` body, `+0x70` flag          | single-point `2/0`, zone `3/0`, wide-tracking `0/0`, all `0/1`                                |
| `shutter_type`     | `+0x12E`                            | mechanical `0`, electronic `1`, mech+elec `2`, EFC `3`, EFC+mech `4`, EFC+mech+elec `5`       |
| `self_timer`       | `+0x86`                             | off `0`, 2s `1`, 10s `2`                                                                      |
| `d_range_priority` | `+0x5E` body, `+0x3B9` flag         | off `4/0`, weak `3/0`, strong `2/1`, auto `0/1` (flag = the DR-boost modes)                   |
| `afc_custom`       | `+0x111`                            | set1..set5 = `0`..`4` (SET2/4 by the confirmed linear spacing)                                |
| `image_size`       | `+0x26`                             | l `0`, m `1`, s `2`                                                                           |
| `aspect_ratio`     | `+0x28`                             | 3:2 `1`, 16:9 `2`, 1:1 `3`                                                                    |
| `raw_recording`    | `+0xE9`                             | uncompressed `0`, lossless-compressed `1`, compressed `2`                                     |
| `num_focus_points` | `+0x110`                            | 117 `0`, 425 `1` (editable only in Single Point AF)                                           |
| `instant_af`       | `+0x12B`                            | af-s `0`, af-c `1`                                                                            |
| `detection`        | `+0x103`,`+0x106`,`+0x109`,`+0x10C` | off, face, face+eye-auto/right/left, subject-animal/bird/automobile/motorcycle/airplane/train |

Confirmed on/off toggles, also by menu name: `af_point_display` (on/off; its flag
`+0x3B5` runs opposite the body), `interlock_spot_ae`, `release_priority_afs` /
`release_priority_afc` (release/focus), `flicker_reduction` (first-frame/all-frames),
`lmo` (on/off), `pre_af` (on `0`/off `1`, body-only), and `af_mf` (preamble `-0x41`,
on `1`/off `0`). The look field `grain` now takes `Off` too (roughness code `2`).
Unconfirmed toggles (single diff, direction unknown, so they take the raw byte
`0`/`1`): `dof_scale`, `self_timer_lamp`, `save_self_timer`, `interval_priority`,
`preshot_es`, `sports_finder`.

A field pairing a body byte with a trailer flag writes both; the trailer block is
absent from the truncated last slot (C7 ends near `+0x37C`), so a trailer-flagged
field there raises rather than writing past the record. The `detection` cluster is
all body bytes (`<= +0x10C`), so it writes on every slot including C7. **Still
unmapped:** the two unidentified per-slot trailer flags `+0x3AE` and `+0x3BD`, and
the min-shutter ladder's slow tail past 1s (indices 21-25).

## The whole-file checksum (solved, confirmed on hardware)

The camera validates a whole-file checksum on restore: an edited blob whose
checksum does not match its own bytes is rejected with PTP `0x200F`. The algorithm
was recovered by reverse-engineering the FUJIFILM X Acquire SDK (`XGFXAPI.dll`,
`FTLPTP.dll`) alongside five controlled X-T5 captures, and it reproduces all five
exactly. It is **not** a CRC:

- **16-bit little-endian additive byte-sum**, stored at `+0xE8`.
- **Covered range:** the payload `[0xA8, EOF)` (start = header u32 `@0x098`,
  length = header u32 `@0x0A0`).
- **Skipped:** the four-byte checksum field `[0xE8, 0xEC)`, and a lens sub-block
  `[0x7B1E, 0x7B29)`.
- **Bias:** `+0xF936`. So `checksum = (sum(covered) + 0xF936) & 0xFFFF`.

`fuji_backup.blob_checksum()` implements it; `helios fuji-settings edit`
recomputes it after a patch.

**The field at `+0xE8` is a u32, not a u16.** The low half is the checksum; the
high half (`+0xEA`) is a small counter, `0x0001` in one capture and `0x0000` in
the rest. The sum must skip all four bytes. Skipping only the low two summed that
stray count and produced a checksum one too high, which is exactly what sank the
first edited restore: helios wrote `0x022E` for a blob whose true value was
`0x022D`, and the camera rejected it with `0x200F`. Excluding the whole field
fixed it, and the same edit was accepted on the next try. `apply_checksum` writes
only the low u16 and leaves the counter as the camera set it.

**Confirmed end to end.** Editing the C7 slot name in a backup and restoring it
applied on the camera: the new name read back over USB and showed in the camera
menu. Only the global checksum needed recomputing.

**There is no per-record integrity/generation token.** `fuji-settings
commit-probe` settled this on 2026-07-16: editing one slot, restoring, power
cycling, and three-way diffing the re-saved record showed the camera re-stamped
**nothing inside the record**, only a global lens/state block (`0x7aac..0x7b24`)
it accepts stale on restore. So the whole-file `0xE8` checksum is the only
integrity gate, which is why every slot's look commits in a single restore (see
FUJI_WRITE_SURFACE.md, "Restoring many slots at once"). The record trailer
`+0x37C..0x3FF` holds settings, not a check; some of the bytes there that "move
with content" (`0x3B8`, `0x3E8`) fall exactly on the **next slot's preamble**
offsets (long-exp NR `-0x48`, WB mode `-0x18`), which helios already writes.

**One camera-managed field to know about.** On each save the camera bumps a small
counter at file offset `+0x584` (u16, values 2 and 3 across our captures). Because
that byte is inside the covered range, the camera's own stored checksum follows by
the same delta: that is why the after-restore backup reads `0x022E` though we sent
`0x022D`. The camera incremented `+0x584` and recomputed. An offline edit leaves
`+0x584` alone and the camera re-stamps it on save, so no action is needed.

**Still fit to the samples on hand.** The `0xF936` bias absorbs whatever is
constant across our captures, so an edit touching a genuinely-excluded region we
never saw vary could still be mis-summed. Fields beyond the slot name (auto-ISO,
the packed recipe bytes) live in the same record region and should apply the same
way, but only the name edit is hardware-confirmed so far. Re-validate a new kind
of edit against a fresh camera backup the first time.

## Restore transport (solved)

Restore works. It is plain PTP: `SendObjectInfo` (`0x100C`) then `SendObject`
(`0x100D`) to object handle 0, the libfuji sequence. No vendor operations, no
handshake, no property write. The bug was a 12-byte-too-long ObjectInfo.

The ObjectInfo dataset is **1076 bytes** (`0x434`), and only three of them are
non-zero: `ObjectFormat` = `0x5000` (offset 4) and `ObjectCompressedSize` = the
blob length (offset 8). `StorageID`, `ProtectionStatus`, and every string and
thumbnail field are zero. `SendObjectInfo` takes params `(0, 0)` (StorageID 0,
parent 0).

helios used to pad the ObjectInfo to **1088 bytes**, which is `1076 + 12`, the
12-byte PTP container header counted twice. The camera accepted the too-long
`SendObjectInfo` and then denied the `SendObject` data phase with `PTP 0x200F`
(Access_Denied), even for a pristine blob. Trimming the dataset to exactly 1076
bytes clears it. `OBJECTINFO_SIZE = 1076` in `fuji_settings.py`.

This killed an earlier theory that the write was gated on Fuji vendor operations
(`0x9002`/`0x900C`/`0x900D`, which the X-T5 does advertise in backup mode). A
capture of a real restore shows none of them: the whole session is standard PTP,
plus X Acquire polling `GetDevicePropValue(0xD20B)` and `GetDeviceInfo` in a loop
for its UI. Those vendor ops belong to some other SDK feature, not backup restore.

### How it was captured

X Acquire is Fuji's own backup/restore tool, Windows only, so it ran in a Windows
VM (quickemu) with the camera passed through by USB id. usbmon on the **host**
still sees every URB even when the device is handed to the guest, because the
traffic crosses the host controller either way. Recipe, if this ever needs
redoing (movie slots, the clarity-write quirk, another body):

1. Load usbmon on the host: `sudo modprobe usbmon`.
2. Pass the camera to a Windows guest running X Acquire (match on vendor:product,
   e.g. `04cb:02fc`). Host-side ACL on `/dev/bus/usb/...` must let your user claim
   it; logind's uaccess handles this for a local session.
3. Capture the all-buses monitor: `dumpcap -i usbmon0 -w restore.pcapng`.
4. In X Acquire, save the settings to a file, then load them back (the restore).
5. usbmon captures don't tag the PTP interface class, so Wireshark leaves it as
   raw `usb`. Reassemble the PTP containers by hand: each starts with a 12-byte
   header (u32 length, u16 type `1=cmd 2=data 3=resp`, u16 code, u32 txn), then
   parameters or the data payload. A short Python pass over `tshark -e usb.capdata`
   output is enough.

`edit` produces a correct offline file with a valid checksum, and `restore` now
writes it back, so the blob-only settings (auto-ISO in particular) are editable
end to end. The recipe path (`fuji-recipes`, PTP property writes) is unchanged.

## Method / how to extend this map

Fast path, for anything that is also a recipe field (no camera needed once you
have one varied backup):

1. `helios fuji-recipes backup` to save the current slots as recipe files, and
   `helios fuji-settings backup` for the matching blob.
2. `helios fuji-settings correlate BLOB.DAT --recipes DIR`. For each known field
   it prints the offset and encoding that reproduces every slot; an affine hit
   (`value = a + b*raw`) is a solved encoding, a `partition` hit needs a second
   capture to disambiguate. The more distinct the slot values, the sharper the
   result.
3. Add solved offsets to `KNOWN_FIELDS`/`decode_recipe_fields` in
   `fuji_backup.py` and record the encoding here.

Slow path, for fields not in the recipe view (WB details, AF, drive) or to
disambiguate partition-only hits:

1. On the camera, make two slots identical except one known setting; re-backup.
2. `helios fuji-settings diff NEW.DAT --slots i,j` (within one file) or
   `helios fuji-settings diff OLD.DAT NEW.DAT` (same slot across two files).
3. Differing bytes annotated `unknown` are the setting's footprint.

Keep sample backups out of git: they embed the camera serial number and the
recipe names. Redact the serial if a test fixture is wanted.

## Sources

- Transport: libfuji `lib/fuji_usb.c` (handle 0, format `0x5000`).
- PTP recipe property map (the `0xD18E-0xD1A5` view): filmkit
  `src/profile/preset-translate.ts`, and libgphoto2 / libfuji for global
  device-property names.
- Whole-file checksum algorithm and the restore opcode sequence: FUJIFILM X
  Acquire (Windows v1.29.0), `XGFXAPI.dll` (`XSDK_GetBackupSettings` /
  `XSDK_SetBackupSettings`, class `CCameraCommandBackupSettings`) and `FTLPTP.dll`
  (the PTP vendor-op transport), statically analyzed. Checksum cross-checked
  against four controlled X-T5 captures.
- Whole-file checksum breadcrumb (pointed near `0xE4/0xE5` on a GFX100s, a
  different body): DPReview GFX100s decode thread (above).
