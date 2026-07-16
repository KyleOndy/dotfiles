# What you can write to an X-T5 via backup restore

This is the field-oriented answer to "what settings can we push to the camera by
editing a backup file." For the byte-level record layout and how each offset was
found, see [FUJI_BLOB_FORMAT.md](FUJI_BLOB_FORMAT.md). For the reverse-engineering
history and open questions, see [FUJI_RESEARCH.md](FUJI_RESEARCH.md).

Everything here is X-T5 (X-Processor 5) only.

## Two write paths

There are two ways to change the seven custom slots. They cover different fields
and, it turns out, commit very differently.

- **Backup restore (this doc):** edit a `.bak` offline, restore the whole file.
  `fuji-settings edit` then `fuji-settings restore`. This is the only path to
  auto-ISO, the only viable path to clarity on the X-T5, and the one that
  **commits persistently** (the edited slot survives a power cycle and shows no
  unsaved-changes flag).
- **PTP recipe properties:** `fuji-recipes restore` writes the per-slot image
  look over USB device properties. It never sees auto-ISO, the X-T5 rejects its
  clarity write, and with AUTO UPDATE CUSTOM SETTING off it leaves the slots
  flagged "unsaved changes" rather than committing them.

The two share one recipe file format, so a single YAML describes a slot for
either path.

## How restore works

The camera exposes the whole settings blob as PTP object handle 0 in USB RAW
CONV./BACKUP RESTORE mode. Restore is plain PTP: `SendObjectInfo` with a
1076-byte ObjectInfo, then `SendObject` with the file. No vendor ops.

The file carries a whole-file checksum at `0xE8`. `edit` recomputes it, so an
edited file is internally valid.

**Restore needs a clean camera state.** If the slots are sitting in an unsaved-
changes state (from a prior PTP recipe write or uncommitted menu edits) or the
USB session is stale, the camera denies the write with PTP `0x200F`. That is
Access Denied, not a checksum error: an unedited backup with a correct checksum
fails the same way. Power cycle the camera, re-enter backup/restore mode, and run
restore as the first operation. Then it applies, and a second power cycle makes
every setting take effect.

## Restoring many slots at once (resolved 2026-07-16)

The picture, established by controlled restores on the X-T5:

- **Image-quality / look fields have no per-restore limit.** Film sim, dynamic
  range, color, tones, color chrome, grain, clarity, sharpness, WB shift,
  high-ISO NR, and the preamble fields (WB mode, color temp, long-exp NR), across
  **all seven slots in a single restore**, are accepted and commit. Verified with a
  one-byte-per-slot seven-slot edit and with the full look of all seven recipes in
  one pass. This is the part of "restore the whole camera in one go" that works.
- **Slot names are capped by a camera-side name buffer.** Renaming is what actually
  blocks a full seven-recipe restore, and it has nothing to do with a slot count,
  see the next section.

### The "four-slot limit" was really the name budget

An earlier sweep reported that five-or-more changed slots were denied with `0x200F`
and called it a four-slot transport cap. That framing is wrong. Look-field changes
have no such cap (seven at once is fine). What is capped is **slot renames**, by a
camera-side **total slot-name-length budget**: the restore path validates the sum
of all seven names against a limited name store and denies (`0x200F`, in the
`SendObject` data phase) when it overflows.

On this X-T5 the seven recipe names summed to **105 characters** and did not fit,
six committed but the seventh was rejected. The practical ceiling sits in the mid-90s
of total characters and is sensitive to how the names are applied (a clean
multi-rename from a fresh backup packs better than renaming one slot at a time),
consistent with a limited, possibly-fragmenting name store. Look fields are exempt,
only names count against it.

Two things make it worse and are worth knowing:

- **The post-name tag at `+0x1E9`** (`CC24`/`CC60` on factory/swept slots; empty on
  user-named slots) must be cleared when renaming. Leaving a stale non-empty tag
  makes the camera reject a restore that renames two or more tagged slots. helios
  now clears it in `patch_slot_name`, which is required for `--recipe-dir` renames
  to land.
- `0x200F` is **overloaded** (Access_Denied): it is also returned for a
  not-clean-state restore (uncommitted menu edits, a prior PTP recipe write, a
  stale session). So the durable rule still holds, **restore from a clean state as
  the first operation** (power cycle, re-enter RAW CONV./BACKUP RESTORE mode), which
  also rules that out as a cause when diagnosing a name-budget denial.

**Working around the name cap:** restore all looks in one pass (unlimited), then
apply names within the budget. If the seven names overflow it, shorten some (trim
`"Kodak "` prefixes and the like) until the total fits, or set the odd name from the
camera menu, which does not go through this restore-path buffer.

### The commit-probe finding (consistent with the above)

`fuji-settings commit-probe` (edit one slot, restore, power-cycle, re-backup,
three-way diff) established there is **no per-slot integrity/generation token** in
the record: committing a one-slot C7 edit re-stamped nothing inside the record. The
only bytes the camera changed that helios did not write are a **global** block below
the records (`0x7aac..0x7b24`: a base64 state string near `0x7a98` and a lens-info
block, ASCII `LX244A` / serial `6BC07576`, one byte inside the checksum-skipped lens
window), accepted **stale** on restore. So the whole-file checksum is the only
integrity gate, and the name cap is a capacity limit on a name store, not a
per-record check. The probe also hardware-confirmed that blob-restore commits
wb-shift-R, high-ISO-NR, and sharpness, not just the name.

## The save/commit model

The camera keeps two representations of a custom slot: the committed slot, and a
working overlay for the currently-active setting.

- A **backup reads the committed slots.** A blob **restore writes the committed
  slots** directly, which is why an edited restore persists.
- **Menu edits with AUTO UPDATE CUSTOM SETTING off go to the working overlay.**
  They are not in a backup and do not persist until you commit them, either by
  turning auto-update on or with EDIT/SAVE CUSTOM SETTING.

So for reverse-engineering a menu setting, either enable auto-update first or
save the slot, or the change will not show up in the backup.

## The workflow

```
fuji-settings backup                        # pristine .bak, keep it
fuji-settings edit BACKUP --slot 7 --recipe c7.yaml
fuji-settings edit BACKUP --recipe-dir DIR  # builds a full seven-slot file
fuji-settings diff BACKUP BACKUP-edited     # sanity: only intended bytes moved
fuji-settings restore BACKUP-edited         # clean state; power-cycle after
```

`edit` reports a per-field before/after for each slot, plus any fields it could
not write, and recomputes the checksum. It writes a new file and refuses to
overwrite the input.

`edit --recipe-dir` builds a valid seven-slot file, and `restore` writes every
slot's **look** in one pass. Restore from a clean state as the first operation. The
only catch is slot **names**: if the seven names overflow the camera name buffer
(mid-90s of total characters) the restore is denied, so keep the names short enough
or set the odd one from the camera menu (see "Restoring many slots at once" above).

## The catalog

Offsets are relative to the start of a slot record, except the three preamble
fields, which sit at fixed distances _before_ the record start (see the preamble
note below). "Blob write" is whether `fuji-settings edit` can set the field.

### Image-quality look

| Field                   | Blob offset    | Encoding                          | Blob write    | PTP fallback                  | Status                        |
| ----------------------- | -------------- | --------------------------------- | ------------- | ----------------------------- | ----------------------------- |
| film_simulation         | +0x4C          | own code table, all 20 mapped     | yes           | yes                           | full table, sweep-confirmed   |
| dynamic_range           | +0x5C          | index 0/1/2/3 = Auto/100/200/400  | yes           | yes                           | offline-verified              |
| color (chroma)          | +0x5F          | `7 - raw`                         | yes           | yes                           | offline-verified              |
| sharpness               | +0x61          | `4 - raw`                         | yes           | yes                           | hardware-confirmed            |
| highlight_tone          | +0x63          | `-2 + 0.5*raw`                    | yes           | yes                           | offline-verified              |
| shadow_tone             | +0x65          | `-2 + 0.5*raw`                    | yes           | yes                           | offline-verified              |
| color_chrome            | +0x67          | 0/1/2 = Off/Weak/Strong           | yes           | yes                           | offline-verified              |
| color_chrome_fx_blue    | +0x68          | 0/1/2 = Off/Weak/Strong           | yes           | yes                           | offline-verified              |
| grain                   | +0x69, +0x6A   | strength byte, size byte          | yes (not Off) | yes                           | Off not located               |
| smooth_skin             | +0x6B          | 0/1/2 = Off/Weak/Strong           | yes           | yes                           | sweep-confirmed               |
| high_iso_nr             | +0x22          | `raw - 4`, integer -4..+4         | yes           | yes                           | hardware-confirmed            |
| clarity                 | +0x25          | `raw - 6`, integer -5..+5         | yes           | no (X-T5 rejects PTP)         | hardware-confirmed, JPEG only |
| wb_shift_r / wb_shift_b | +0x06 / +0x08  | `9 - raw`, integer -9..+9         | yes           | yes                           | hardware-confirmed (R)        |
| mono_wc                 | +0x5A          | `raw - 18`, integer -9..+9        | yes           | yes                           | sweep-confirmed (mono sims)   |
| mono_mg                 | +0x58          | `raw - 18`, integer -9..+9        | yes           | yes                           | sweep-confirmed (mono sims)   |
| white_balance           | preamble -0x18 | mode code table (12 codes mapped) | yes           | partial (no White Pri/Custom) | sweep-confirmed               |
| wb_color_temp           | preamble -0x74 | u16 LE kelvin                     | yes           | yes                           | sweep-confirmed               |
| long_exposure_nr        | preamble -0x48 | off = 1, on = 0                   | yes           | no (PTP hardcodes on)         | sweep-confirmed               |

### Auto-ISO (blob only, no PTP property at all)

| Field                          | Blob offset     | Encoding                             | Blob write         | Status                             |
| ------------------------------ | --------------- | ------------------------------------ | ------------------ | ---------------------------------- |
| auto_iso default (AUTO1-3)     | +0x92 (3 bytes) | 1/3-stop index, `ISO_THIRDS[20-idx]` | yes                | hardware-confirmed                 |
| auto_iso max (AUTO1-3)         | +0x95 (3 bytes) | full-stop index, `12800 >> idx`      | yes                | hardware-confirmed                 |
| auto_iso min_shutter (AUTO1-3) | +0x98 (3 bytes) | menu index                           | yes (known speeds) | hardware-confirmed, ladder partial |

### Slot metadata

| Field     | Blob offset | Encoding                       | Blob write | Status             |
| --------- | ----------- | ------------------------------ | ---------- | ------------------ |
| slot name | +0x1CF      | NUL-terminated ASCII, 25 chars | yes        | hardware-confirmed |

## The per-slot preamble

Three fields do not live in the 0x400 record body: white balance mode, color
temperature, and long-exposure NR. They sit in a small block just _before_ each
record start, at fixed distances back (`-0x74` color temp, `-0x48` long-exp NR,
`-0x18` WB mode). The encoder writes them at those absolute offsets; they are
covered by the whole-file checksum like everything else. This is almost certainly
where the other per-custom-slot settings (AF, drive, image size) live too, still
to be mapped.

## Status legend

- **hardware-confirmed:** edited, restored, power-cycled, and read back on the
  camera. The edit-and-restore workflow itself is proven this way: a slot changed
  in a file (name, film sim, sharpness) survives a power cycle and shows no
  unsaved flag.
- **sweep-confirmed:** located and encoded by a multi-slot camera sweep (seven
  slots per backup, each field on a distinct value so one backup gives the whole
  encoding curve), cross-checked against a baseline. The encoder is the exact
  inverse of the decoder and reproduces every sample backup byte-for-byte (32
  backups, 224 slot records).
- **offline-verified:** exact inverse of the decoder, reproduces every sample
  backup, and sits in the same checksummed record region as the confirmed fields.

## Known gaps

- **White Priority and Custom decode but do not yet author from a file:** the
  three auto variants (Auto 0x00, White Priority 0x01, Ambience Priority 0x02) and
  one Custom (0x0B) are mapped, and the blob encoder can write all of them. But the
  shared recipe validator only accepts the PTP mode names, so a recipe file naming
  White Priority or Custom is rejected before it reaches the blob encoder. Wiring
  those two blob-only modes through the validator is a small follow-up. Whether
  Custom 2/3 take 0x0C/0x0D is also untested. An unmapped mode decodes as `?0xNN`
  and round trips, but writing one raises.
- **Grain Off:** +0x69/+0x6A cannot express Off; the on/off byte is not located,
  so `edit` refuses `grain: Off`. Weak and Strong work.
- **Min-shutter ladder:** only a handful of menu positions are mapped. An
  unmapped speed raises.
- **The rest of the preamble:** AF mode, image size/quality, RAW recording, and
  the other per-custom-slot settings are stored per slot but not yet located.
