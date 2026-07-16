"""Parser for the Fujifilm whole-camera BACKUP/RESTORE blob.

This is the `.DAT`/`.bak` file the camera writes in USB RAW CONV./BACKUP
RESTORE mode (the same object fuji_settings.py transfers as PTP object handle
0). It is a SEPARATE format from the per-slot PTP device properties that
fuji_recipes.py reads: the blob carries the full per-slot custom settings,
including data the PTP recipe properties never expose (auto-ISO, lens info).

Everything here was reverse engineered by diffing controlled X-T5 captures
(change one known setting, re-backup, diff); see FUJI_BLOB_FORMAT.md for the
method, the field table, and what is verified vs still unknown. No public prior
art documents this blob layout: a GitHub code search for the FUJIFILMX-BACKUP
magic returns nothing (2026-07). Offsets/encodings are confirmed on the X-T5
(X-Processor 5) only, so the parser refuses other models unless forced.
"""

MAGIC = b"FUJIFILMX-BACKUP"

# header, all at fixed byte offsets from the start of the file
OFF_VERSION = 0x10  # 4 ASCII digits, e.g. "0100"
OFF_MODEL = 0x14  # NUL-terminated ASCII, e.g. "X-T5"
OFF_SERIAL = 0x34  # NUL-terminated ASCII

SUPPORTED_MODELS = ("X-T5",)

# Whole-file checksum. Reverse engineered from the FUJIFILM X Acquire SDK plus
# five controlled X-T5 captures: a 16-bit little-endian additive byte-sum over
# the payload region [0xA8, EOF), skipping its own four-byte checksum field and a
# lens sub-block, offset by a fixed bias. The camera validates this on restore
# and recomputes it when settings change. The payload window matches the header:
# u32 @0x98 = 0xA8 (start) and u32 @0xA0 = filesize - 0xA8 (length). See
# FUJI_BLOB_FORMAT.md.
#
# The field at 0xE8 is a u32: the low u16 is the checksum, the high u16 a small
# counter (0x0001 in one capture, 0x0000 in the rest). The sum must skip all four
# bytes, not just the low two, or a nonzero high half leaks a stray count into
# the total. That off-by-one is exactly what sank the first edited-blob restore:
# helios summed 0xEA, wrote a checksum one too high, and the camera rejected it
# with PTP 0x200F. Excluding the whole field reproduces every capture on hand,
# bias unchanged. apply_checksum writes only the low u16, leaving the counter as
# the camera set it.
CHECKSUM_OFF = 0xE8  # u16 LE checksum (low half of the u32 field at 0xE8)
CHECKSUM_PAYLOAD_START = 0xA8
CHECKSUM_SKIP = ((0xE8, 0xEC), (0x7B1E, 0x7B29))
CHECKSUM_BIAS = 0xF936

# Bytes the camera rewrites on every save regardless of which slot changed, so a
# commit-probe three-way diff must not mistake them for a per-slot token: the u16
# save counter at 0x584 (see the checksum note in FUJI_BLOB_FORMAT.md) and the
# whole-file checksum u32 field at 0xE8.
SAVE_COUNTER_OFF = 0x584
GLOBAL_BOOKKEEPING = (
    (SAVE_COUNTER_OFF, SAVE_COUNTER_OFF + 2),
    (CHECKSUM_OFF, CHECKSUM_OFF + 4),
)

# Global (not per-slot) settings, found while diffing per-slot changes. Drive mode
# is a physical dial position stored once here, not per bank. The lens/state block
# is the sub-block the camera re-stamps on every save (it is excluded from the
# checksum, see CHECKSUM_SKIP); its bytes move each save independent of content.
DRIVE_MODE_OFF = 0x700
LENS_STATE_BLOCK = (0x7AAC, 0x7B29)

# The custom-setting slots are stored as NUM_SLOTS fixed-size records at the
# tail of the file, one per C1-C7. Records are RECORD_SIZE-aligned; the file
# ends inside the last record (trailing padding is trimmed). All field offsets
# below are relative to the start of a record.
RECORD_SIZE = 0x400
NUM_SLOTS = 7

REL_NAME = 0x1CF  # slot name, NUL-terminated ASCII
REL_POSTNAME = 0x1E9  # 4 ASCII bytes ("CC24", "CC60", ...); a base-preset marker
POSTNAME_LEN = 4
# The name field runs from REL_NAME up to the tag at REL_POSTNAME.
NAME_FIELD_LEN = REL_POSTNAME - REL_NAME  # 26 bytes

# Auto-ISO block: 9 contiguous bytes, three banks (AUTO1/2/3) x three params,
# laid out [default x3][max x3][minShutter x3]. Verified against a controlled
# backup that reproduced both a control slot (125/6400/AUTO on all banks) and a
# test slot (160/400 1/500, 640/3200 1/60, 1600/12800 1/8) exactly.
REL_AUTOISO = 0x92
AUTOISO_LEN = 9

# Default sensitivity is a 1/3-stop index counting down from 12800: index 0 =
# 12800 ... index 20 = 125. So value = ISO_THIRDS[20 - index].
ISO_THIRDS = [
    125,
    160,
    200,
    250,
    320,
    400,
    500,
    640,
    800,
    1000,
    1250,
    1600,
    2000,
    2500,
    3200,
    4000,
    5000,
    6400,
    8000,
    10000,
    12800,
]

# Min shutter is a menu-list index. Swept on the X-T5 (round 12) by setting the
# three AUTO1/2/3 banks to known speeds and reading them back three per backup.
# The ladder runs in 1/3-stop steps through the fast region (indices 4-13) then
# widens to full stops once slow (15=1/30, 16=1/15, 17=1/8, 18=1/4, 20=1s). AUTO
# is the sentinel 26. Only measured positions are listed; the 1/3-stop gaps
# (5/6/9/11/12/14) and 19=1/2 are inferred and left out so a write cannot pick an
# unverified index, and the slow tail past 1s (21-25) is still unmeasured.
MIN_SHUTTER = {
    4: "1/500",
    7: "1/250",
    8: "1/200",
    10: "1/125",
    13: "1/60",
    15: "1/30",
    16: "1/15",
    17: "1/8",
    18: "1/4",
    20: "1s",
    26: "AUTO",
}

# ---------------------------------------------------------------------------
# Packed per-slot image-quality struct (the "recipe look").
#
# These single-byte fields sit in a compact run at record +0x4C..+0x6A. They
# were located offline by known-plaintext correlation: a backup whose seven
# slots held seven recipes with known values, matched byte-for-byte against the
# saved recipe files (see FUJI_BLOB_FORMAT.md, "packed recipe struct"). Every
# encoding below reproduces all seven slots exactly. NOTE the blob uses its own
# codes, distinct from the PTP recipe property codes in fuji_recipes.py.
REL_FILM_SIM = 0x4C
REL_DYNAMIC_RANGE = 0x5C
REL_COLOR = 0x5F  # chroma; value = 7 - raw
REL_SHARPNESS = 0x61  # value = 4 - raw
REL_HIGHLIGHT_TONE = 0x63  # value = -2 + 0.5 * raw
REL_SHADOW_TONE = 0x65  # value = -2 + 0.5 * raw
REL_COLOR_CHROME = 0x67
REL_COLOR_CHROME_FX_BLUE = 0x68
REL_GRAIN_STRENGTH = 0x69
REL_GRAIN_SIZE = 0x6A
REL_SMOOTH_SKIN = 0x6B  # Off/Weak/Strong = 0/1/2 (X-T5 multi-slot sweep)

# Monochromatic color, active only for mono film sims. Located by multi-slot
# sweep: value = raw - 18, integer -9..+9 (raw 9..27). +0x58 is MG, +0x5A is WC.
REL_MONO_MG = 0x58
REL_MONO_WC = 0x5A
MONO_SHIFT_BIAS = 18

# High-ISO NR at +0x22, its own byte ahead of the packed struct. Multi-slot
# sweep: value = raw - 4, integer -4..+4 (raw 0..8). The blob stores it linearly,
# unlike the non-linear PTP HIGH_ISO_NR property table.
REL_HIGH_ISO_NR = 0x22
HIGH_ISO_NR_BIAS = 4

# Clarity sits on its own at +0x25, well ahead of the packed struct. Located by
# controlled single-variable diff on the X-T5 (change only clarity, re-backup,
# diff): value = raw - 6, integer, raw 1..11 for clarity -5..+5. Clarity is greyed
# out on the camera under HEIF, so it only takes effect when the slot's image
# format is JPEG (see the format byte at +0xEB).
REL_CLARITY = 0x25
CLARITY_BIAS = 6

# White balance shift R/B, one byte each, located by controlled single-variable
# diff and cross-checked against the PTP shift values: value = 9 - raw, integer
# -9..+9 (raw 0..18). +0x08 is WB shift B, not a second film-sim copy as an
# earlier diff guessed.
REL_WB_SHIFT_R = 0x06
REL_WB_SHIFT_B = 0x08
WB_SHIFT_BIAS = 9
# Image format flag at +0xEB: HEIF = 0x01, JPEG = 0x00 (X-T5, controlled diff).
# Not part of the recipe look, but it gates whether clarity applies.
REL_IMAGE_FORMAT = 0xEB

# ---------------------------------------------------------------------------
# Per-slot preamble. Each 0x400 record body is preceded by a small block that
# holds settings the body does not: white balance mode, color temperature, and
# long-exposure NR. These live at fixed distances *before* the record start
# (found by an X-T5 multi-slot sweep). PREAMBLE_SIZE is how many bytes back we
# read; for slot 1 the block sits just ahead of the first record.
PREAMBLE_SIZE = 0x74
PRE_COLOR_TEMP = 0x74  # u16 LE kelvin, meaningful only when WB is Color Temp
PRE_IMAGE_QUALITY = 0x4C  # raw/jpeg component; pairs with the body byte +0x29
PRE_LONG_EXP_NR = 0x48  # 1 = off, 0 = on (inverted from the PTP property)
PRE_AF_MF = 0x41  # AF+MF: 1 = on, 0 = off (X-T5 round 11; both toggle directions)
PRE_WB_MODE = 0x18  # white balance mode code

# Blob white-balance mode codes (X-T5 multi-slot sweep, plus Fluorescent 3 = 0x07
# read from a real CineStill slot). Partial: the modes not yet exercised (Auto
# Ambience Priority, custom WB) are unmapped and fall in the gaps at 0x01, 0x02;
# an unmapped code renders "?0xNN".
BLOB_WHITE_BALANCE = {
    0x00: "Auto",
    0x01: "Auto White Priority",
    0x02: "Auto Ambience Priority",
    0x03: "Daylight",
    0x04: "Shade",
    0x05: "Fluorescent 1",
    0x06: "Fluorescent 2",
    0x07: "Fluorescent 3",
    0x08: "Incandescent",
    0x09: "Underwater",
    0x0A: "Color Temp",
    0x0B: "Custom",
}
WB_COLOR_TEMP_NAME = "Color Temp"

# Blob film-sim codes, all 20 mapped by an X-T5 multi-slot sweep (seven slots
# per backup, three backups covering the whole menu). Unlisted codes still render
# as "?0xNN" so an unexpected value round trips. NOTE these are the blob's own
# codes, distinct from the PTP film-sim codes in fuji_recipes.py.
BLOB_FILM_SIM = {
    0x01: "Provia",
    0x02: "Astia",
    0x04: "Velvia",
    0x06: "Sepia",
    0x09: "Monochrome",
    0x0A: "Monochrome+R",
    0x0B: "Monochrome+Ye",
    0x0C: "Monochrome+G",
    0x0D: "Pro Neg Std",
    0x0E: "Pro Neg Hi",
    0x0F: "Classic Chrome",
    0x10: "Classic Neg",
    0x11: "Nostalgic Neg",
    0x12: "Eterna",
    0x13: "Eterna Bleach Bypass",
    0x15: "Acros",
    0x16: "Acros+R",
    0x17: "Acros+Ye",
    0x18: "Acros+G",
    0x19: "Reala Ace",
}
# film sims that suppress the chroma color field, keyed by the decoded name so
# it works for any sim once its code is known
MONO_SIM_NAMES = {
    "Monochrome",
    "Monochrome+Ye",
    "Monochrome+R",
    "Monochrome+G",
    "Sepia",
    "Acros",
    "Acros+Ye",
    "Acros+R",
    "Acros+G",
}
BLOB_DYNAMIC_RANGE = {
    0x00: "Auto",
    0x01: 100,
    0x02: 200,
    0x03: 400,
}  # all X-T5-verified
BLOB_STRENGTH = {0x00: "Off", 0x01: "Weak", 0x02: "Strong"}
# Grain roughness is a 3-value enum, not a 2-way toggle: "Off" is code 2 in the
# same byte (X-T5 round 11), so there is no separate on/off gate. When roughness
# is Off the size byte is ignored, and the recipe value is just "Off".
BLOB_GRAIN_STRENGTH = {0x00: "Strong", 0x01: "Weak", 0x02: "Off"}
BLOB_GRAIN_SIZE = {0x00: "Small", 0x01: "Large"}

# ---------------------------------------------------------------------------
# Encode side: inverse tables and helpers for writing a recipe back into a
# record. Every encoder below is the exact inverse of its decode_* counterpart,
# so decoding a record and re-encoding the result reproduces the original bytes
# (verified against the sample X-T5 backups). The encoder writes only the
# specific offsets it has mapped, never the whole struct run, so unknown and
# constant bytes round trip untouched.


def _normalize(text):
    return "".join(ch for ch in str(text).lower() if ch.isalnum())


# normalized name -> blob code, inverted from the decode tables. Partial where
# the decode table is partial (film sim); an unmappable value raises rather than
# writing a wrong byte.
BLOB_FILM_SIM_ENCODE = {_normalize(name): code for code, name in BLOB_FILM_SIM.items()}
BLOB_WHITE_BALANCE_ENCODE = {
    _normalize(name): code for code, name in BLOB_WHITE_BALANCE.items()
}
BLOB_STRENGTH_ENCODE = {_normalize(name): code for code, name in BLOB_STRENGTH.items()}
BLOB_GRAIN_STRENGTH_ENCODE = {
    _normalize(name): code for code, name in BLOB_GRAIN_STRENGTH.items()
}
BLOB_GRAIN_SIZE_ENCODE = {
    _normalize(name): code for code, name in BLOB_GRAIN_SIZE.items()
}
MIN_SHUTTER_ENCODE = {label: idx for idx, label in MIN_SHUTTER.items()}
ISO_THIRDS_INDEX = {iso: i for i, iso in enumerate(ISO_THIRDS)}
# full-stop max-ISO menu values (12800 >> index), the inverse of decode_max_iso
MAX_ISO_INDEX = {12800 >> i: i for i in range(8)}

# recipe fields with no located blob offset yet. Every look and preamble field
# an X-T5 backup carries is now mapped, so this is empty; patch_slot_recipe still
# returns anything left here so a future gap can fall back to the PTP path.
BLOB_UNLOCATED_KEYS = ()


def _tidy(value):
    return int(value) if value == int(value) else value


def decode_recipe_fields(record):
    """Decode the per-slot image-quality look from the packed +0x4C..0x6A struct.

    Returns a dict of the fields reverse engineered so far; anything not yet
    located (white balance, WB shift, clarity, high-ISO NR) is simply absent.
    Verified against the recipe view on the X-T5; see FUJI_BLOB_FORMAT.md.
    """
    if len(record) <= REL_GRAIN_SIZE:
        return {}

    sim_raw = record[REL_FILM_SIM]
    sim = BLOB_FILM_SIM.get(sim_raw, f"?0x{sim_raw:02X}")
    is_mono = sim in MONO_SIM_NAMES

    out = {"film_simulation": sim}
    dr = record[REL_DYNAMIC_RANGE]
    out["dynamic_range"] = BLOB_DYNAMIC_RANGE.get(dr, dr)
    if not is_mono:
        out["color"] = 7 - record[REL_COLOR]
    out["sharpness"] = 4 - record[REL_SHARPNESS]
    out["highlight_tone"] = _tidy(-2 + 0.5 * record[REL_HIGHLIGHT_TONE])
    out["shadow_tone"] = _tidy(-2 + 0.5 * record[REL_SHADOW_TONE])
    out["color_chrome"] = BLOB_STRENGTH.get(
        record[REL_COLOR_CHROME], record[REL_COLOR_CHROME]
    )
    out["color_chrome_fx_blue"] = BLOB_STRENGTH.get(
        record[REL_COLOR_CHROME_FX_BLUE], record[REL_COLOR_CHROME_FX_BLUE]
    )
    strength = BLOB_GRAIN_STRENGTH.get(record[REL_GRAIN_STRENGTH])
    size = BLOB_GRAIN_SIZE.get(record[REL_GRAIN_SIZE])
    if strength == "Off":
        out["grain"] = "Off"
    elif strength and size:
        out["grain"] = f"{strength}/{size}"
    clarity_raw = record[REL_CLARITY]
    if CLARITY_BIAS - 5 <= clarity_raw <= CLARITY_BIAS + 5:
        out["clarity"] = clarity_raw - CLARITY_BIAS
    for key, rel in (("wb_shift_r", REL_WB_SHIFT_R), ("wb_shift_b", REL_WB_SHIFT_B)):
        raw = record[rel]
        if 0 <= raw <= 2 * WB_SHIFT_BIAS:
            out[key] = WB_SHIFT_BIAS - raw
    nr_raw = record[REL_HIGH_ISO_NR]
    if 0 <= nr_raw <= 2 * HIGH_ISO_NR_BIAS:
        out["high_iso_nr"] = nr_raw - HIGH_ISO_NR_BIAS
    if is_mono:
        for key, rel in (("mono_wc", REL_MONO_WC), ("mono_mg", REL_MONO_MG)):
            raw = record[rel]
            if 0 <= raw <= 2 * MONO_SHIFT_BIAS:
                out[key] = raw - MONO_SHIFT_BIAS
    if len(record) > REL_SMOOTH_SKIN and record[REL_SMOOTH_SKIN] in BLOB_STRENGTH:
        out["smooth_skin"] = BLOB_STRENGTH[record[REL_SMOOTH_SKIN]]
    return out


def decode_slot_preamble(preamble):
    """Decode the per-slot preamble (white balance, color temp, long-exp NR).

    `preamble` is the PREAMBLE_SIZE bytes immediately before a record start
    (Record.preamble). Offsets are measured from the record start, so they index
    from the end of the block. wb_color_temp is only reported when the mode is
    Color Temp, matching the recipe schema.
    """
    out = {}
    if len(preamble) < PREAMBLE_SIZE:
        return out
    wb_raw = preamble[PREAMBLE_SIZE - PRE_WB_MODE]
    out["white_balance"] = BLOB_WHITE_BALANCE.get(wb_raw, f"?0x{wb_raw:02X}")
    out["long_exposure_nr"] = (
        "off" if preamble[PREAMBLE_SIZE - PRE_LONG_EXP_NR] else "on"
    )
    out["af_mf"] = "on" if preamble[PREAMBLE_SIZE - PRE_AF_MF] else "off"
    if out["white_balance"] == WB_COLOR_TEMP_NAME:
        lo = preamble[PREAMBLE_SIZE - PRE_COLOR_TEMP]
        hi = preamble[PREAMBLE_SIZE - PRE_COLOR_TEMP + 1]
        out["wb_color_temp"] = lo | (hi << 8)
    return out


def decode_slot(record):
    """Full per-slot decode: the packed look, preamble, and menu settings."""
    out = decode_recipe_fields(record.data)
    out.update(decode_slot_preamble(record.preamble))
    out.update(decode_slot_fields(record.data))
    iq = decode_image_quality(record.data, record.preamble)
    if iq is not None:
        out["image_quality"] = iq
    detection = decode_detection(record.data)
    if detection is not None:
        out["detection"] = detection
    return out


class BackupFormatError(Exception):
    pass


def read_c_string(data, off, limit=32):
    end = data.find(b"\x00", off, off + limit)
    if end == -1:
        end = off + limit
    return data[off:end].decode("ascii", "replace")


def parse_header(data):
    if data[: len(MAGIC)] != MAGIC:
        raise BackupFormatError(
            f"not a Fujifilm backup: missing {MAGIC!r} magic at offset 0"
        )
    return {
        "version": data[OFF_VERSION : OFF_VERSION + 4].decode("ascii", "replace"),
        "model": read_c_string(data, OFF_MODEL),
        "serial": read_c_string(data, OFF_SERIAL),
    }


def decode_default_iso(index):
    if 0 <= index <= 20:
        return str(ISO_THIRDS[20 - index])
    return f"?idx{index}"


def decode_max_iso(index):
    # full-stop index counting down from 12800
    if 0 <= index <= 20:
        return str(12800 >> index)
    return f"?idx{index}"


def decode_min_shutter(index):
    return MIN_SHUTTER.get(index, f"?idx{index}")


def decode_auto_iso(record):
    """Return the three auto-ISO banks as dicts, or None if out of range."""
    blk = record[REL_AUTOISO : REL_AUTOISO + AUTOISO_LEN]
    if len(blk) < AUTOISO_LEN:
        return None
    defaults, maxes, shutters = blk[0:3], blk[3:6], blk[6:9]
    banks = []
    for i in range(3):
        banks.append(
            {
                "default": decode_default_iso(defaults[i]),
                "max": decode_max_iso(maxes[i]),
                "min_shutter": decode_min_shutter(shutters[i]),
            }
        )
    return banks


def encode_default_iso(value):
    """Inverse of decode_default_iso: ISO value -> 1/3-stop index."""
    iso = int(value)
    if iso not in ISO_THIRDS_INDEX:
        raise ValueError(f"auto-ISO default {value!r} is not a 1/3-stop ISO value")
    return 20 - ISO_THIRDS_INDEX[iso]


def encode_max_iso(value):
    """Inverse of decode_max_iso: full-stop ISO value -> index."""
    iso = int(value)
    if iso not in MAX_ISO_INDEX:
        raise ValueError(f"auto-ISO max {value!r} is not a full-stop ISO value")
    return MAX_ISO_INDEX[iso]


def encode_min_shutter(label):
    """Inverse of decode_min_shutter: menu label -> index."""
    label = str(label)
    if label not in MIN_SHUTTER_ENCODE:
        known = ", ".join(str(v) for v in MIN_SHUTTER_ENCODE)
        raise ValueError(
            f"auto-ISO min shutter {label!r} is not a mapped menu position "
            f"(known: {known}); sweep the menu to complete MIN_SHUTTER"
        )
    return MIN_SHUTTER_ENCODE[label]


def encode_auto_iso(record, banks):
    """Write the 9-byte auto-ISO block; inverse of decode_auto_iso.

    `record` is a mutable bytearray; `banks` is a list of three dicts with
    'default', 'max' and 'min_shutter' (the shape decode_auto_iso returns).
    Layout is [default x3][max x3][min_shutter x3] at REL_AUTOISO.
    """
    if len(banks) != 3:
        raise ValueError(f"auto_iso needs exactly 3 banks, got {len(banks)}")
    defaults = [encode_default_iso(b["default"]) for b in banks]
    maxes = [encode_max_iso(b["max"]) for b in banks]
    shutters = [encode_min_shutter(b["min_shutter"]) for b in banks]
    record[REL_AUTOISO : REL_AUTOISO + AUTOISO_LEN] = bytes(defaults + maxes + shutters)


def _clamp_byte(value, field):
    raw = int(round(value))
    if not 0 <= raw <= 0xFF:
        raise ValueError(f"{field}: encoded value {raw} is out of byte range")
    return raw


def _encode_dynamic_range(value):
    if isinstance(value, str):
        if _normalize(value) in ("auto", "drauto"):
            return 0x00
        raise ValueError(f"dynamic_range: unknown value {value!r}")
    inv = {v: k for k, v in BLOB_DYNAMIC_RANGE.items() if isinstance(v, int)}
    if value not in inv:
        raise ValueError(f"dynamic_range: unsupported value {value!r}")
    return inv[value]


def _encode_grain(record, value):
    if _normalize(value) == "off":
        # roughness code 2 = Off; the size byte is ignored, leave it untouched
        record[REL_GRAIN_STRENGTH] = BLOB_GRAIN_STRENGTH_ENCODE["off"]
        return
    parts = str(value).split("/")
    if len(parts) != 2:
        raise ValueError(f"grain {value!r} must look like 'Weak/Small' (strength/size)")
    strength = BLOB_GRAIN_STRENGTH_ENCODE.get(_normalize(parts[0]))
    size = BLOB_GRAIN_SIZE_ENCODE.get(_normalize(parts[1]))
    if strength is None or size is None:
        raise ValueError(f"grain {value!r}: unknown strength or size")
    record[REL_GRAIN_STRENGTH] = strength
    record[REL_GRAIN_SIZE] = size


def _blob_enum_code(table, value):
    """Blob code for a name, or the raw byte from a '?0xNN' passthrough. Returns
    None when the name is unknown and it is not a ?0xNN literal, so a decoded
    unmapped code round trips even though it has no name."""
    raw = table.get(_normalize(value))
    if raw is not None:
        return raw
    text = str(value).strip().lower()
    if text.startswith("?0x"):
        return int(text[3:], 16)
    return None


def encode_recipe_fields(record, recipe):
    """Write the packed image-quality look into a record; inverse of
    decode_recipe_fields. Mutates the bytearray `record` in place, touching only
    the specific mapped offsets (never the constant sub-struct or the still
    unknown bytes in the +0x4C..0x6A run). Returns the list of recipe fields that
    were requested but have no blob offset yet, so the caller can report them.
    """
    if "film_simulation" in recipe:
        code = _blob_enum_code(BLOB_FILM_SIM_ENCODE, recipe["film_simulation"])
        if code is None:
            raise ValueError(
                f"blob film-sim code for {recipe['film_simulation']!r} is not "
                f"mapped yet; only {', '.join(BLOB_FILM_SIM.values())} are known"
            )
        record[REL_FILM_SIM] = code

    if "dynamic_range" in recipe:
        record[REL_DYNAMIC_RANGE] = _encode_dynamic_range(recipe["dynamic_range"])

    if "color" in recipe:
        record[REL_COLOR] = _clamp_byte(7 - recipe["color"], "color")
    if "sharpness" in recipe:
        record[REL_SHARPNESS] = _clamp_byte(4 - recipe["sharpness"], "sharpness")
    if "highlight_tone" in recipe:
        record[REL_HIGHLIGHT_TONE] = _clamp_byte(
            2 * recipe["highlight_tone"] + 4, "highlight_tone"
        )
    if "shadow_tone" in recipe:
        record[REL_SHADOW_TONE] = _clamp_byte(
            2 * recipe["shadow_tone"] + 4, "shadow_tone"
        )

    for key, rel in (
        ("color_chrome", REL_COLOR_CHROME),
        ("color_chrome_fx_blue", REL_COLOR_CHROME_FX_BLUE),
    ):
        if key in recipe:
            code = BLOB_STRENGTH_ENCODE.get(_normalize(recipe[key]))
            if code is None:
                raise ValueError(f"{key}: unknown value {recipe[key]!r}")
            record[rel] = code

    if "grain" in recipe:
        _encode_grain(record, recipe["grain"])

    if "clarity" in recipe:
        record[REL_CLARITY] = _clamp_byte(recipe["clarity"] + CLARITY_BIAS, "clarity")

    for key, rel in (("wb_shift_r", REL_WB_SHIFT_R), ("wb_shift_b", REL_WB_SHIFT_B)):
        if key in recipe:
            record[rel] = _clamp_byte(WB_SHIFT_BIAS - recipe[key], key)

    if "high_iso_nr" in recipe:
        record[REL_HIGH_ISO_NR] = _clamp_byte(
            recipe["high_iso_nr"] + HIGH_ISO_NR_BIAS, "high_iso_nr"
        )
    if "smooth_skin" in recipe:
        code = BLOB_STRENGTH_ENCODE.get(_normalize(recipe["smooth_skin"]))
        if code is None:
            raise ValueError(f"smooth_skin: unknown value {recipe['smooth_skin']!r}")
        record[REL_SMOOTH_SKIN] = code
    for key, rel in (("mono_wc", REL_MONO_WC), ("mono_mg", REL_MONO_MG)):
        if key in recipe:
            record[rel] = _clamp_byte(recipe[key] + MONO_SHIFT_BIAS, key)

    return [k for k in BLOB_UNLOCATED_KEYS if k in recipe]


def _encode_long_exp_nr(value):
    """Long-exposure NR blob byte: 1 = off, 0 = on (inverted from the PTP
    property). Accepts on/off strings and booleans."""
    if isinstance(value, bool):
        return 0 if value else 1
    text = _normalize(value)
    if text in ("off", "0", "false", "no"):
        return 1
    if text in ("on", "1", "true", "yes"):
        return 0
    raise ValueError(f"long_exposure_nr: expected on/off, got {value!r}")


def _encode_af_mf(value):
    """AF+MF preamble byte: 1 = on, 0 = off (X-T5 round 11). Accepts on/off
    strings and booleans."""
    if isinstance(value, bool):
        return 1 if value else 0
    text = _normalize(value)
    if text in ("on", "1", "true", "yes"):
        return 1
    if text in ("off", "0", "false", "no"):
        return 0
    raise ValueError(f"af_mf: expected on/off, got {value!r}")


def encode_slot_preamble(out, start, recipe):
    """Write the preamble fields (white balance mode, color temp, long-exp NR)
    for the slot whose record body begins at absolute offset `start`. Mutates the
    whole-file bytearray `out` in place. Only fields present in the recipe are
    written; every other preamble byte is left untouched.
    """
    if "white_balance" in recipe:
        code = _blob_enum_code(BLOB_WHITE_BALANCE_ENCODE, recipe["white_balance"])
        if code is None:
            raise ValueError(
                f"blob white-balance code for {recipe['white_balance']!r} is not "
                f"mapped yet; known modes: {', '.join(BLOB_WHITE_BALANCE.values())}"
            )
        out[start - PRE_WB_MODE] = code
    if "wb_color_temp" in recipe:
        kelvin = int(recipe["wb_color_temp"])
        out[start - PRE_COLOR_TEMP] = kelvin & 0xFF
        out[start - PRE_COLOR_TEMP + 1] = (kelvin >> 8) & 0xFF
    if "long_exposure_nr" in recipe:
        out[start - PRE_LONG_EXP_NR] = _encode_long_exp_nr(recipe["long_exposure_nr"])
    if "af_mf" in recipe:
        out[start - PRE_AF_MF] = _encode_af_mf(recipe["af_mf"])


def _signature(vec):
    """Reduce a value vector to its equality pattern, e.g. (7,7,3)->(0,0,1)."""
    seen = {}
    out = []
    for v in vec:
        seen.setdefault(v, len(seen))
        out.append(seen[v])
    return tuple(out)


def _read_as(interp, record, off):
    if off + (2 if "16" in interp else 1) > len(record):
        return None
    if interp == "u8":
        return record[off]
    if interp == "i8":
        return record[off] - 256 if record[off] >= 128 else record[off]
    raw = int.from_bytes(record[off : off + 2], "little" if "le" in interp else "big")
    if interp.startswith("i16"):
        return raw - 65536 if raw >= 32768 else raw
    return raw


CORRELATE_INTERPS = ("u8", "i8", "u16le", "i16le", "u16be")


def _affine_fit(xs, ys):
    """Solve ys = a + b*xs exactly over the samples, or return None."""
    pts = list(zip(xs, ys))
    for i in range(len(pts)):
        for j in range(i + 1, len(pts)):
            (x1, y1), (x2, y2) = pts[i], pts[j]
            if x1 == x2:
                continue
            b = (y2 - y1) / (x2 - x1)
            a = y1 - b * x1
            if all(abs((a + b * x) - y) < 1e-9 for x, y in pts):
                return a, b
    return None


def correlate(records, truth):
    """Locate blob offsets for known per-slot settings (a layout RE aid).

    `records` is the list of per-slot record byte strings; `truth` maps a field
    name to its known value per slot (None where a slot lacks the field). For
    each field this matches the across-slot equality pattern of every
    byte/word offset, and for numeric fields also solves an exact affine
    encoding (value = a + b*raw). Returns {field: [(off, interp, note), ...]}.
    This is how the +0x4C..0x6A struct was mapped; see FUJI_BLOB_FORMAT.md.
    """
    results = {}
    size = min(len(r) for r in records)
    for field, values in truth.items():
        idx = [i for i, v in enumerate(values) if v is not None]
        wanted = [values[i] for i in idx]
        if len(set(wanted)) < 2:
            results[field] = []  # constant across slots: nothing to correlate
            continue
        numeric = all(
            isinstance(v, (int, float)) and not isinstance(v, bool) for v in wanted
        )
        target = _signature(wanted)
        hits = []
        for interp in CORRELATE_INTERPS:
            width = 2 if "16" in interp else 1
            for off in range(size - width + 1):
                raw = [_read_as(interp, records[i], off) for i in idx]
                if None in raw or len(set(raw)) < 2:
                    continue
                if _signature(raw) != target:
                    continue
                note = "partition"
                if numeric:
                    fit = _affine_fit(raw, wanted)
                    if fit is not None:
                        a, b = fit
                        note = f"value = {a:g} + {b:g}*raw"
                hits.append((off, interp, note))
        results[field] = hits
    return results


# ---------------------------------------------------------------------------
# AF/MF, drive and shooting fields, located by controlled single-variable diffs
# on an X-T5: set exactly one custom-bank setting in one of C1-C7, re-backup, and
# whole-file diff (see FUJI_BLOB_FORMAT.md, "Per-slot AF/drive/shooting fields").
# Many pair a value byte in the record body with an on/off bit in the trailer
# flags block at +0x3AE..+0x3D3. These are single data points: the byte locations
# are solid, but multi-value encodings (enums, durations) are not fully swept, so
# no decoders yet. Image Quality also has a preamble byte (PRE_IMAGE_QUALITY);
# RAW-only greys and zeroes the JPEG sliders and locks image size. Note the camera
# stores several menu items GLOBALLY, not per bank (see the NOT-per-slot list in
# FUJI_BLOB_FORMAT.md): color space, AF illuminator, wrap focus point, MF assist,
# IS mode, focus check, touch screen mode, and drive mode (DRIVE_MODE_OFF).
REL_IMAGE_SIZE = 0x26
REL_ASPECT_RATIO = 0x28  # 3:2/16:9/1:1 = 1/2/3; independent of the size byte +0x26
REL_IMAGE_QUALITY = 0x29
REL_D_RANGE_PRIORITY = 0x5E  # own byte, distinct from dynamic range at +0x5C
REL_AF_MODE = 0x6C
REL_AF_MODE_ALL = (
    0x70  # "ALL" AF-mode flag; Wide/Tracking and ALL share 0x6C=0 (round 7)
)
REL_SPORTS_FINDER = 0x84
REL_PRESHOT_ES = 0x85
REL_SELF_TIMER = 0x86
REL_SAVE_SELF_TIMER = 0x88
REL_SELF_TIMER_LAMP = 0x89
REL_PRE_AF = 0x8A
REL_RELEASE_PRIORITY_AFS = 0x8B  # AF-S sub-option; AF-C is the next byte
REL_RELEASE_PRIORITY_AFC = 0x8C
REL_INTERLOCK_SPOT_AE = 0x9F
REL_INTERVAL_PRIORITY = 0xE8
REL_RAW_RECORDING = 0xE9
REL_FLICKER_REDUCTION = 0xEC
# Detection cluster (X-T5 rounds 9-10). Face/eye and subject detection are
# mutually exclusive and selected by the pair (+0x103, +0x10C): face/eye = (1,1),
# subject = (0,0), off = (0,1). The active family's parameter then lives in its
# own body byte: eye submode at +0x106 (face/eye), subject type at +0x109.
REL_DETECTION_MODE = 0x103  # face/eye(1) vs subject(0) selector
REL_EYE_SUBMODE = 0x106  # auto/right/left/off = 0/1/2/3 (only in face/eye mode)
REL_SUBJECT_TYPE = 0x109  # animal..train = 0..5 (only in subject mode)
REL_DETECTION_MODE2 = 0x10C  # second selector byte; 1 = face/eye or off, 0 = subject
REL_AF_POINT_DISPLAY = 0x10F
REL_NUM_FOCUS_POINTS = 0x110
REL_AFC_CUSTOM = 0x111
REL_INSTANT_AF = 0x12B
REL_DOF_SCALE = 0x12D
REL_SHUTTER_TYPE = 0x12E
# Trailer flags block: per-slot on/off bits, the enable half of some settings.
# +0x3AE was tagged the shutter flag in round 3, but round 8 shows shutter type
# changing without it moving, so it is an unidentified per-slot flag, not shutter
# (shutter type is body-only at +0x12E).
REL_UNKNOWN_3AE = 0x3AE
REL_FLAG_FACE_EYE = 0x3B2
REL_FLAG_PRE_AF = 0x3B3
REL_FLAG_AF_POINT_DISPLAY = 0x3B5
REL_FLAG_LMO = 0x3B7  # lens modulation optimizer, flag only (no body value byte)
REL_FLAG_D_RANGE_PRIORITY = 0x3B9
# +0x3BD was tagged AF+MF from a round-3 diff, but round 11 shows AF+MF toggling
# the preamble byte -0x41 (PRE_AF_MF) in both directions while +0x3BD never moves
# (C2 sits stuck at 6). So +0x3BD is an unidentified per-slot flag, not AF+MF.
REL_UNKNOWN_3BD = 0x3BD
REL_FLAG_SUBJECT_DETECT = 0x3BF
REL_FLAG_DOF_SCALE = 0x3D3

# Known record fields, for annotating raw diffs. Each entry is
# (rel_offset, length, label); anything outside these ranges prints as unknown.
KNOWN_FIELDS = [
    (REL_WB_SHIFT_R, 1, "wb shift R"),
    (REL_WB_SHIFT_B, 1, "wb shift B"),
    (REL_CLARITY, 1, "clarity"),
    (REL_HIGH_ISO_NR, 1, "high-ISO NR"),
    (REL_IMAGE_FORMAT, 1, "image format (HEIF/JPEG)"),
    (REL_FILM_SIM, 1, "film simulation"),
    (REL_MONO_MG, 1, "mono MG"),
    (REL_MONO_WC, 1, "mono WC"),
    (REL_SMOOTH_SKIN, 1, "smooth skin"),
    (REL_DYNAMIC_RANGE, 1, "dynamic range"),
    (REL_COLOR, 1, "color (chroma)"),
    (REL_SHARPNESS, 1, "sharpness"),
    (REL_HIGHLIGHT_TONE, 1, "highlight tone"),
    (REL_SHADOW_TONE, 1, "shadow tone"),
    (REL_COLOR_CHROME, 1, "color chrome"),
    (REL_COLOR_CHROME_FX_BLUE, 1, "color chrome FX blue"),
    (REL_GRAIN_STRENGTH, 1, "grain strength"),
    (REL_GRAIN_SIZE, 1, "grain size"),
    (REL_AUTOISO + 0, 3, "auto_iso default (banks 1-3)"),
    (REL_AUTOISO + 3, 3, "auto_iso max (banks 1-3)"),
    (REL_AUTOISO + 6, 3, "auto_iso min_shutter (banks 1-3)"),
    (REL_NAME, 26, "slot name"),
    (REL_POSTNAME, 4, "post-name ASCII tag"),
    # AF/MF, drive and shooting fields (controlled single-variable diffs, X-T5)
    (REL_IMAGE_SIZE, 1, "image size"),
    (REL_ASPECT_RATIO, 1, "aspect ratio"),
    (REL_IMAGE_QUALITY, 1, "image quality"),
    (REL_D_RANGE_PRIORITY, 1, "d-range priority"),
    (REL_AF_MODE, 1, "AF mode"),
    (REL_AF_MODE_ALL, 1, "AF mode ALL flag"),
    (REL_SPORTS_FINDER, 1, "sports finder mode"),
    (REL_PRESHOT_ES, 1, "pre-shot ES"),
    (REL_SELF_TIMER, 1, "self-timer"),
    (REL_SAVE_SELF_TIMER, 1, "save self-timer setting"),
    (REL_SELF_TIMER_LAMP, 1, "self-timer lamp"),
    (REL_PRE_AF, 1, "pre-AF"),
    (REL_RELEASE_PRIORITY_AFS, 1, "release/focus priority AF-S"),
    (REL_RELEASE_PRIORITY_AFC, 1, "release/focus priority AF-C"),
    (REL_INTERLOCK_SPOT_AE, 1, "interlock spot AE & focus area"),
    (REL_INTERVAL_PRIORITY, 1, "interval priority mode"),
    (REL_RAW_RECORDING, 1, "raw recording"),
    (REL_FLICKER_REDUCTION, 1, "flicker reduction"),
    (REL_DETECTION_MODE, 1, "detection selector (face/eye vs subject)"),
    (REL_EYE_SUBMODE, 1, "eye detection submode"),
    (REL_SUBJECT_TYPE, 1, "subject detection type"),
    (REL_DETECTION_MODE2, 1, "detection selector (second byte)"),
    (REL_AF_POINT_DISPLAY, 1, "AF point display"),
    (REL_NUM_FOCUS_POINTS, 1, "number of focus points"),
    (REL_AFC_CUSTOM, 1, "AF-C custom settings"),
    (REL_INSTANT_AF, 1, "instant AF setting"),
    (REL_DOF_SCALE, 1, "depth-of-field scale"),
    (REL_SHUTTER_TYPE, 1, "shutter type"),
    (REL_UNKNOWN_3AE, 1, "unknown per-slot flag +0x3ae"),
    (REL_FLAG_FACE_EYE, 1, "face/eye detection (flag)"),
    (REL_FLAG_PRE_AF, 1, "pre-AF (flag)"),
    (REL_FLAG_AF_POINT_DISPLAY, 1, "AF point display (flag)"),
    (REL_FLAG_LMO, 1, "lens modulation optimizer (flag)"),
    (REL_FLAG_D_RANGE_PRIORITY, 1, "d-range priority (flag)"),
    (REL_UNKNOWN_3BD, 1, "unknown per-slot flag +0x3bd"),
    (REL_FLAG_SUBJECT_DETECT, 1, "subject detection (flag)"),
    (REL_FLAG_DOF_SCALE, 1, "depth-of-field scale (flag)"),
]


def field_label(rel):
    for start, length, label in KNOWN_FIELDS:
        if start <= rel < start + length:
            return label
    return "unknown"


# ---------------------------------------------------------------------------
# Per-slot menu settings writable through the blob restore path: the AF/MF,
# drive and shooting fields from the custom-bank EDIT/CHECK menu, each a body
# byte (and sometimes a paired trailer-flag byte) inside the record. The live PTP
# recipe path never exposes these; only the blob carries them. Located by
# controlled single-variable X-T5 diffs (FUJI_BLOB_FORMAT.md).
#
# Each field maps a token to a (body_value, flag_value) pair; flag_value is None
# for a body-only field, body_value is None for a flag-only field. "confirmed"
# means the diff campaign recorded the menu label on each side, so the tokens are
# menu names (or the point count for num_focus_points) and only those values
# encode. An unconfirmed field never had its labels recorded, so its tokens are
# the raw bytes 0 and 1 and, being body-only, it also accepts any raw byte 0-255
# (read it back with 'inspect' and copy it); helios never prints or writes a
# guessed label. af_point_display's flag runs opposite its body; d_range_priority's
# flag tracks the DR-boost modes, not a simple on/off.
#
# Every offset here lives inside the 0x400 record. The last slot (C7) is truncated
# in the file (it ends around +0x37C), so its trailer-flag block is absent; a
# flagged field aimed at C7 raises rather than writing past the record.
BLOB_SLOT_FIELDS = {
    # --- multi-value enums, fully swept and labeled (X-T5 rounds 6-8) ---
    "af_mode": {
        "body": REL_AF_MODE,
        "flag": REL_AF_MODE_ALL,
        "confirmed": True,
        "values": {
            "single-point": (2, 0),
            "zone": (3, 0),
            "wide-tracking": (0, 0),
            "all": (0, 1),
        },
    },
    "shutter_type": {
        "body": REL_SHUTTER_TYPE,
        "flag": None,
        "confirmed": True,
        "values": {
            "mechanical": (0, None),
            "electronic": (1, None),
            "mech+elec": (2, None),
            "electronic-front-curtain": (3, None),
            "efc+mech": (4, None),
            "efc+mech+elec": (5, None),
        },
    },
    "self_timer": {
        "body": REL_SELF_TIMER,
        "flag": None,
        "confirmed": True,
        "values": {"off": (0, None), "2s": (1, None), "10s": (2, None)},
    },
    "d_range_priority": {
        "body": REL_D_RANGE_PRIORITY,
        "flag": REL_FLAG_D_RANGE_PRIORITY,
        "confirmed": True,
        "values": {
            "off": (4, 0),
            "weak": (3, 0),
            "strong": (2, 1),
            "auto": (0, 1),
        },
    },
    "afc_custom": {
        "body": REL_AFC_CUSTOM,
        "flag": None,
        "confirmed": True,
        # SET1/3/5 = 0/2/4 observed; SET2/4 = 1/3 by the confirmed linear spacing
        "values": {
            "set1": (0, None),
            "set2": (1, None),
            "set3": (2, None),
            "set4": (3, None),
            "set5": (4, None),
        },
    },
    "image_size": {
        "body": REL_IMAGE_SIZE,
        "flag": None,
        "confirmed": True,
        # L/M/S; independent of aspect_ratio (+0x28), which is its own key
        "values": {"l": (0, None), "m": (1, None), "s": (2, None)},
    },
    "aspect_ratio": {
        "body": REL_ASPECT_RATIO,
        "flag": None,
        "confirmed": True,
        # X-T5 round 10; code 0 is unseen so only 3:2/16:9/1:1 encode
        "values": {"3:2": (1, None), "16:9": (2, None), "1:1": (3, None)},
    },
    "raw_recording": {
        "body": REL_RAW_RECORDING,
        "flag": None,
        "confirmed": True,
        # X-T5 rounds 1 + 10 (all three values captured)
        "values": {
            "uncompressed": (0, None),
            "lossless-compressed": (1, None),
            "compressed": (2, None),
        },
    },
    "num_focus_points": {
        "body": REL_NUM_FOCUS_POINTS,
        "flag": None,
        "confirmed": True,
        "values": {117: (0, None), 425: (1, None)},
    },
    # --- confirmed on/off (and A/B) toggles ---
    "af_point_display": {
        "body": REL_AF_POINT_DISPLAY,
        "flag": REL_FLAG_AF_POINT_DISPLAY,
        "confirmed": True,
        "values": {"on": (1, 0), "off": (0, 1)},
    },
    "interlock_spot_ae": {
        "body": REL_INTERLOCK_SPOT_AE,
        "flag": None,
        "confirmed": True,
        "values": {"on": (1, None), "off": (0, None)},
    },
    "release_priority_afs": {
        "body": REL_RELEASE_PRIORITY_AFS,
        "flag": None,
        "confirmed": True,
        "values": {"release": (0, None), "focus": (1, None)},
    },
    "release_priority_afc": {
        "body": REL_RELEASE_PRIORITY_AFC,
        "flag": None,
        "confirmed": True,
        "values": {"release": (0, None), "focus": (1, None)},
    },
    "flicker_reduction": {
        "body": REL_FLICKER_REDUCTION,
        "flag": None,
        "confirmed": True,
        "values": {"first-frame": (0, None), "all-frames": (1, None)},
    },
    "lmo": {
        "body": None,
        "flag": REL_FLAG_LMO,
        "confirmed": True,
        "values": {"on": (None, 0), "off": (None, 1)},
    },
    # pre_af direction confirmed in round 11 (on = 0, off = 1); only the body byte
    # +0x8A moved, so the flag +0x3B3 is not paired here. instant_af is the AF-ON
    # button's AF-S/AF-C mode (round 11: AF-S = 0, AF-C = 1).
    "pre_af": {
        "body": REL_PRE_AF,
        "flag": None,
        "confirmed": True,
        "values": {"on": (0, None), "off": (1, None)},
    },
    "instant_af": {
        "body": REL_INSTANT_AF,
        "flag": None,
        "confirmed": True,
        "values": {"af-s": (0, None), "af-c": (1, None)},
    },
    # unconfirmed: byte and the observed pair are known, the menu mapping is not,
    # so the tokens are the raw bytes. Read the value back with 'inspect' and copy
    # it. dof_scale is pixel/film-format basis.
    "dof_scale": {
        "body": REL_DOF_SCALE,
        "flag": REL_FLAG_DOF_SCALE,
        "confirmed": False,
        "values": {0: (0, 0), 1: (1, 1)},
    },
    "self_timer_lamp": {
        "body": REL_SELF_TIMER_LAMP,
        "flag": None,
        "confirmed": False,
        "values": {0: (0, None), 1: (1, None)},
    },
    "save_self_timer": {
        "body": REL_SAVE_SELF_TIMER,
        "flag": None,
        "confirmed": False,
        "values": {0: (0, None), 1: (1, None)},
    },
    "interval_priority": {
        "body": REL_INTERVAL_PRIORITY,
        "flag": None,
        "confirmed": False,
        "values": {0: (0, None), 1: (1, None)},
    },
    "preshot_es": {
        "body": REL_PRESHOT_ES,
        "flag": None,
        "confirmed": False,
        "values": {0: (0, None), 1: (1, None)},
    },
    "sports_finder": {
        "body": REL_SPORTS_FINDER,
        "flag": None,
        "confirmed": False,
        "values": {0: (0, None), 1: (1, None)},
    },
}

SLOT_FIELD_KEYS = tuple(BLOB_SLOT_FIELDS)

# Image quality is the one field split across two bytes in two places: a 0-4 menu
# index in the record body (+0x29) and a RAW-mode companion in the preamble
# (-0x4C). Fully swept on the X-T5 (round 7); see FUJI_BLOB_FORMAT.md.
# token -> (body +0x29, preamble -0x4C)
IMAGE_QUALITY_VALUES = {
    "fine": (0x00, 0x00),
    "normal": (0x01, 0x00),
    "fine+raw": (0x02, 0x02),
    "normal+raw": (0x03, 0x02),
    "raw": (0x04, 0x01),
}


def _image_quality_pair(value):
    """Resolve image_quality to (body +0x29, preamble -0x4C). Raises ValueError."""
    norm = _normalize(value)
    pair = next(
        (v for tok, v in IMAGE_QUALITY_VALUES.items() if _normalize(tok) == norm), None
    )
    if pair is None:
        known = ", ".join(IMAGE_QUALITY_VALUES)
        raise ValueError(f"image_quality: unknown value {value!r} (known: {known})")
    return pair


def _slot_field_pair(spec, value, key):
    """Resolve a recipe value for one slot field to (body_value, flag_value).

    Accepts a known token (menu name, or raw byte for an unconfirmed field), a
    bool for on/off fields, or - only for an unconfirmed body-only field - any raw
    byte. A confirmed field takes only its listed values, so a stray number (e.g.
    self_timer 2) never silently writes the wrong byte. Raises ValueError otherwise.
    """
    values = spec["values"]
    if isinstance(value, bool):
        pair = values.get("on" if value else "off")
    elif isinstance(value, int):
        pair = values.get(value)
    else:
        norm = _normalize(value)
        pair = next(
            (
                p
                for tok, p in values.items()
                if isinstance(tok, str) and _normalize(tok) == norm
            ),
            None,
        )
    if pair is not None:
        return pair
    # raw fallback: only an unconfirmed body-only field (whose tokens already are
    # the raw bytes) accepts an arbitrary byte; a confirmed field must not, or a
    # value like self_timer 2 would be written literally instead of as its code
    if (
        not spec["confirmed"]
        and spec["flag"] is None
        and spec["body"] is not None
        and isinstance(value, int)
        and not isinstance(value, bool)
        and 0 <= value <= 0xFF
    ):
        return (value, None)
    known = ", ".join(str(t) for t in values)
    raise ValueError(f"{key}: unknown value {value!r} (known: {known})")


def check_slot_field(key, value):
    """Validate a recipe slot-field value, raising ValueError if it will not
    encode. Public so fuji_recipes can validate without the private resolvers;
    mirrors how auto_iso reuses the blob encoders.
    """
    if key == "image_quality":
        _image_quality_pair(value)
        return
    if key == "detection":
        _detection_tuple(value)
        return
    spec = BLOB_SLOT_FIELDS.get(key)
    if spec is None:
        raise ValueError(f"{key} is not a known per-slot field")
    _slot_field_pair(spec, value, key)


def encode_slot_fields(record, recipe):
    """Write the mapped per-slot in-record fields into a record bytearray in
    place. Only keys present in the recipe are touched; inverse of
    decode_slot_fields. Raises ValueError for an unencodable value or a flagged
    field aimed at the truncated last slot, whose trailer block the file omits.
    """
    for key, spec in BLOB_SLOT_FIELDS.items():
        if key not in recipe:
            continue
        body_val, flag_val = _slot_field_pair(spec, recipe[key], key)
        for rel, val in ((spec["body"], body_val), (spec["flag"], flag_val)):
            if rel is None or val is None:
                continue
            if rel >= len(record):
                raise ValueError(
                    f"{key}: offset +0x{rel:03x} is past this slot's record "
                    f"({len(record)} bytes); the last slot (C7) is truncated in "
                    "the backup, so set this field on C1-C6 or on the camera"
                )
            record[rel] = val


def encode_image_quality(out, start, value):
    """Write image_quality's two bytes into the whole-file buffer `out`: the body
    index at start +0x29 and the RAW-mode byte at start -0x4C (the preamble)."""
    body, pre = _image_quality_pair(value)
    out[start + REL_IMAGE_QUALITY] = body
    out[start - PRE_IMAGE_QUALITY] = pre


def decode_slot_fields(record):
    """Decode the per-slot in-record fields for display. Confirmed fields report
    their menu name (or the point count for num_focus_points); unconfirmed fields
    report the raw byte. A value outside the observed set shows as the raw byte for
    a body-only field; an unrecognized flagged combination is omitted.
    """
    out = {}
    for key, spec in BLOB_SLOT_FIELDS.items():
        body = spec["body"]
        flag = spec["flag"]
        if body is not None and body >= len(record):
            continue
        if flag is not None and flag >= len(record):
            continue
        bval = record[body] if body is not None else None
        fval = record[flag] if flag is not None else None
        token = next(
            (
                tok
                for tok, (b, f) in spec["values"].items()
                if (b is None or b == bval) and (f is None or f == fval)
            ),
            None,
        )
        if token is not None:
            out[key] = token
        elif flag is None and bval is not None:
            out[key] = bval
    return out


def decode_image_quality(record, preamble):
    """Decode image_quality from the record body (+0x29) and preamble (-0x4C).
    Returns the menu token, or None if the two bytes are an unknown combination."""
    if REL_IMAGE_QUALITY >= len(record) or len(preamble) < PREAMBLE_SIZE:
        return None
    body = record[REL_IMAGE_QUALITY]
    pre = preamble[PREAMBLE_SIZE - PRE_IMAGE_QUALITY]
    return next(
        (tok for tok, (b, p) in IMAGE_QUALITY_VALUES.items() if b == body and p == pre),
        None,
    )


# Detection cluster: face/eye vs subject detection, mutually exclusive, spread
# across four record-body bytes (X-T5 rounds 9-10). Exposed as one recipe key so
# an editor cannot request an impossible face+subject combination. Each token
# writes the full (selector +0x103, eye submode +0x106, subject type +0x109,
# second selector +0x10C) tuple; the byte the active family does not use is
# written 0 to keep the record canonical.
DETECTION_VALUES = {
    "off": (0, 0, 0, 1),
    "face": (1, 3, 0, 1),  # face detection on, eye detection off
    "face+eye-auto": (1, 0, 0, 1),
    "face+eye-right": (1, 1, 0, 1),
    "face+eye-left": (1, 2, 0, 1),
    "subject-animal": (0, 0, 0, 0),
    "subject-bird": (0, 0, 1, 0),
    "subject-automobile": (0, 0, 2, 0),
    "subject-motorcycle": (0, 0, 3, 0),
    "subject-airplane": (0, 0, 4, 0),
    "subject-train": (0, 0, 5, 0),
}
_EYE_SUBMODE_NAMES = {
    0: "face+eye-auto",
    1: "face+eye-right",
    2: "face+eye-left",
    3: "face",
}
_SUBJECT_TYPE_NAMES = {
    0: "subject-animal",
    1: "subject-bird",
    2: "subject-automobile",
    3: "subject-motorcycle",
    4: "subject-airplane",
    5: "subject-train",
}


def _detection_tuple(value):
    """Resolve a detection token to its (+0x103, +0x106, +0x109, +0x10C) tuple."""
    norm = _normalize(value)
    tup = next(
        (v for tok, v in DETECTION_VALUES.items() if _normalize(tok) == norm), None
    )
    if tup is None:
        known = ", ".join(DETECTION_VALUES)
        raise ValueError(f"detection: unknown value {value!r} (known: {known})")
    return tup


def encode_detection(record, value):
    """Write the four detection bytes into a record bytearray in place."""
    v103, v106, v109, v10c = _detection_tuple(value)
    record[REL_DETECTION_MODE] = v103
    record[REL_EYE_SUBMODE] = v106
    record[REL_SUBJECT_TYPE] = v109
    record[REL_DETECTION_MODE2] = v10c


def decode_detection(record):
    """Decode the detection cluster to its recipe token, or None for an unknown
    selector combination. Reads only the byte the active family uses, so a
    leftover eye/type byte from a prior mode does not throw off the decode."""
    if REL_DETECTION_MODE2 >= len(record):
        return None
    selector = (record[REL_DETECTION_MODE], record[REL_DETECTION_MODE2])
    if selector == (0, 1):
        return "off"
    if selector == (1, 1):
        return _EYE_SUBMODE_NAMES.get(record[REL_EYE_SUBMODE])
    if selector == (0, 0):
        return _SUBJECT_TYPE_NAMES.get(record[REL_SUBJECT_TYPE])
    return None


class Record:
    def __init__(self, index, start, data):
        self.index = index  # 1-based slot number (C1..C7)
        self.start = start
        self.data = data[start : start + RECORD_SIZE]
        # per-slot preamble: the PREAMBLE_SIZE bytes just before the record body,
        # holding WB mode, color temp and long-exposure NR (see decode_slot_preamble)
        self.preamble = data[max(0, start - PREAMBLE_SIZE) : start]
        self.name = read_c_string(self.data, REL_NAME)


def locate_records(data):
    last = ((len(data) - 1) // RECORD_SIZE) * RECORD_SIZE
    first = last - (NUM_SLOTS - 1) * RECORD_SIZE
    if first < 0:
        raise BackupFormatError(
            f"file too small to hold {NUM_SLOTS} slot records ({len(data)} bytes)"
        )
    records = [Record(i + 1, first + i * RECORD_SIZE, data) for i in range(NUM_SLOTS)]
    if not any(r.name.strip() for r in records):
        raise BackupFormatError(
            "no readable slot names where the custom-setting records were "
            "expected; the backup layout may differ from the X-T5 format"
        )
    return records


def open_backup(path, force=False):
    """Parse a backup file into (header, [Record, ...])."""
    with open(path, "rb") as f:
        data = f.read()
    header = parse_header(data)
    if header["model"] not in SUPPORTED_MODELS and not force:
        raise BackupFormatError(
            f"backup is from {header['model']!r}; the record layout is only "
            f"verified on {', '.join(SUPPORTED_MODELS)}. Rerun with --force to "
            "parse anyway (offsets may be wrong)."
        )
    return header, locate_records(data)


def patch_slot_name(data, slot_index, new_name):
    """Return a copy of the whole-file blob with one slot's name replaced.

    slot_index is 1-based (C1..C7). The name lives in a NAME_FIELD_LEN-byte,
    NUL-terminated ASCII field at record +REL_NAME; this zero-fills that field
    and writes new_name. It also clears the 4-byte post-name tag at +REL_POSTNAME.
    That tag is a base-preset marker ("CC24", "CC60") on factory/swept slots;
    user-named slots carry an empty tag. Leaving it stale while renaming makes the
    camera reject a restore that renames two or more tagged slots at once (it
    tolerates one), so clearing it is what lets a whole-camera rename restore in a
    single pass, see FUJI_WRITE_SURFACE.md, "The four-slot limit was really the
    name budget".
    The whole-file checksum is left stale for the caller to recompute with
    apply_checksum. Raises BackupFormatError if the records cannot be located,
    ValueError on a bad slot number or a name that will not fit the field.
    """
    records = locate_records(data)
    if not 1 <= slot_index <= NUM_SLOTS:
        raise ValueError(f"slot must be 1..{NUM_SLOTS}, got {slot_index}")
    try:
        encoded = new_name.encode("ascii")
    except UnicodeEncodeError:
        raise ValueError("slot name must be ASCII")
    if len(encoded) > NAME_FIELD_LEN - 1:
        raise ValueError(
            f"slot name is {len(encoded)} bytes; the field holds "
            f"{NAME_FIELD_LEN - 1} characters plus a NUL terminator"
        )
    rec_start = records[slot_index - 1].start
    out = bytearray(data)
    name_start = rec_start + REL_NAME
    out[name_start : name_start + NAME_FIELD_LEN] = encoded.ljust(
        NAME_FIELD_LEN, b"\x00"
    )
    tag_start = rec_start + REL_POSTNAME
    out[tag_start : tag_start + POSTNAME_LEN] = b"\x00" * POSTNAME_LEN
    return bytes(out)


def patch_slot_recipe(data, slot_index, recipe):
    """Return (blob, skipped): a copy of the whole-file blob with one slot's
    packed image-quality look, per-slot menu settings (AF/drive/shooting,
    shutter, image quality), and (when present) auto-ISO block rewritten from a
    recipe dict, plus the list of recipe fields with no blob offset yet.

    slot_index is 1-based (C1..C7). Mirrors patch_slot_name: it edits only the
    record's mapped offsets and leaves the whole-file checksum stale for the
    caller to recompute with apply_checksum. The slot name is left to
    patch_slot_name so the two composers stack. The record length is invariant
    (in-place byte writes). Raises BackupFormatError if the records cannot be
    located, ValueError on a bad slot number or an unencodable value.
    """
    records = locate_records(data)
    if not 1 <= slot_index <= NUM_SLOTS:
        raise ValueError(f"slot must be 1..{NUM_SLOTS}, got {slot_index}")
    out = bytearray(data)
    start = records[slot_index - 1].start
    orig = out[start : start + RECORD_SIZE]
    rec = bytearray(orig)
    skipped = encode_recipe_fields(rec, recipe)
    encode_slot_fields(rec, recipe)
    if "detection" in recipe:
        encode_detection(rec, recipe["detection"])
    if recipe.get("auto_iso"):
        encode_auto_iso(rec, recipe["auto_iso"])
    if len(rec) != len(orig):
        raise BackupFormatError("recipe edit changed the record length")
    out[start : start + len(orig)] = rec
    encode_slot_preamble(out, start, recipe)
    if "image_quality" in recipe:
        encode_image_quality(out, start, recipe["image_quality"])
    return bytes(out), skipped


def blob_checksum(data):
    """Compute the whole-file checksum: the value the camera expects at 0xE8.

    16-bit little-endian additive byte-sum over [0xA8, EOF), skipping the two
    checksum bytes and the lens sub-block, plus a fixed bias (see the CHECKSUM_*
    constants and their caveat). Reproduces every controlled X-T5 capture on
    hand. The skipped ranges include the checksum field itself, so this is
    independent of whatever is currently stored there.
    """
    total = CHECKSUM_BIAS
    for i in range(CHECKSUM_PAYLOAD_START, len(data)):
        if any(lo <= i < hi for lo, hi in CHECKSUM_SKIP):
            continue
        total += data[i]
    return total & 0xFFFF


def stored_checksum(data):
    """Read the checksum currently stored at 0xE8 (u16 LE)."""
    return int.from_bytes(data[CHECKSUM_OFF : CHECKSUM_OFF + 2], "little")


def apply_checksum(data):
    """Return a copy of the blob with the 0xE8 checksum recomputed to match."""
    out = bytearray(data)
    out[CHECKSUM_OFF : CHECKSUM_OFF + 2] = blob_checksum(data).to_bytes(2, "little")
    return bytes(out)


# ---------------------------------------------------------------------------
# Commit-probe: isolate the bytes the camera re-stamps when it saves an edited
# slot. Edit one slot, restore, power-cycle, re-backup, and three-way diff. A byte
# the camera changed that helios never wrote is either a per-slot field the camera
# manages (if inside the edited record) or global state it refreshes on every save
# (lens block, save counter, checksum). Used to confirm there is no per-slot
# integrity token in the record, part of why every slot's look commits in a
# single restore (FUJI_WRITE_SURFACE.md, "Restoring many slots at once").

_PREAMBLE_FIELD_NAMES = {
    PRE_WB_MODE: "wb mode",
    PRE_IMAGE_QUALITY: "image quality",
    PRE_LONG_EXP_NR: "long-exp NR",
    PRE_COLOR_TEMP: "color temp",
    PRE_COLOR_TEMP - 1: "color temp",
}


def _preamble_field(back):
    name = _PREAMBLE_FIELD_NAMES.get(back)
    return f" [{name}]" if name else ""


def _global_bookkeeping(off):
    return any(lo <= off < hi for lo, hi in GLOBAL_BOOKKEEPING)


def describe_offset(records, off):
    """Human label for an absolute file offset, for commit-probe output.

    Names the global bookkeeping fields, then locates the offset in a slot
    record and its field. The trailing PREAMBLE_SIZE bytes of a record
    physically hold the *next* slot's preamble (WB mode, color temp, long-exp NR
    live there, FUJI_BLOB_FORMAT.md), so an offset in that zone is annotated with
    the overlap: that is very likely what the "trailer bytes that move with
    content" at 0x3B8/0x3E8 really are.
    """
    if _global_bookkeeping(off):
        if SAVE_COUNTER_OFF <= off < SAVE_COUNTER_OFF + 2:
            return "save counter +0x584"
        return "whole-file checksum +0xE8"
    if 0xE4 <= off < 0xE6:
        return "checksum/CRC +0xE4 (re-stamped each save)"
    if off == DRIVE_MODE_OFF:
        return "drive mode (global +0x700)"
    if LENS_STATE_BLOCK[0] <= off < LENS_STATE_BLOCK[1]:
        return f"lens/state block +0x{off:04x} (re-stamped each save)"
    for r in records:
        if r.start <= off < r.start + RECORD_SIZE:
            rel = off - r.start
            label = f"C{r.index} +0x{rel:03x} ({field_label(rel)})"
            if rel >= RECORD_SIZE - PREAMBLE_SIZE and r.index < NUM_SLOTS:
                back = RECORD_SIZE - rel
                label += (
                    f" == C{r.index + 1} preamble -0x{back:02x}{_preamble_field(back)}"
                )
            return label
    first = records[0].start
    if first - PREAMBLE_SIZE <= off < first:
        back = first - off
        return f"C1 preamble -0x{back:02x}{_preamble_field(back)}"
    return f"file +0x{off:04x}"


def classify_commit_probe(original, edited, readback, slot_index=None):
    """Three-way per-byte diff for the commit-probe experiment.

    `original` is the pristine backup helios started from, `edited` is the blob
    helios sent, and `readback` is a fresh backup taken after the restore
    committed and the camera power-cycled. Every offset where the three do not
    all agree is bucketed:

      committed:      helios changed it, camera kept it (the edit took)
      reverted:       helios changed it, camera put the original value back
      changed:        helios changed it, camera stored a third value
      stamped:        helios LEFT the original, camera changed it on save, and it
                      sits inside the edited slot's record or preamble -- a real
                      per-slot token candidate
      stamped_global: same, but elsewhere in the file (camera state refresh like
                      the lens block, NOT a per-slot token)
      bookkeeping:    a global field the camera always rewrites (save counter,
                      checksum), regardless of content

    `slot_index` (1-based) is the slot the probe edited; it decides the
    stamped/stamped_global split. With slot_index=None every stamp lands in
    'stamped'. Returns (buckets, records) where records comes from `readback`.
    Compares over the shortest of the three blobs; a length mismatch is left for
    the caller to surface.
    """
    records = locate_records(readback)
    n = min(len(original), len(edited), len(readback))
    slot_lo = slot_hi = None
    if slot_index is not None:
        rec = records[slot_index - 1]
        slot_lo = rec.start - PREAMBLE_SIZE
        slot_hi = rec.start + RECORD_SIZE
    buckets = {
        "committed": [],
        "reverted": [],
        "changed": [],
        "stamped": [],
        "stamped_global": [],
        "bookkeeping": [],
    }
    for off in range(n):
        o, e, b = original[off], edited[off], readback[off]
        if o == e == b:
            continue
        entry = (off, o, e, b, describe_offset(records, off))
        if _global_bookkeeping(off):
            buckets["bookkeeping"].append(entry)
        elif o == e:  # helios left it, camera moved it: a stamp
            in_slot = slot_lo is None or slot_lo <= off < slot_hi
            buckets["stamped" if in_slot else "stamped_global"].append(entry)
        elif e == b:  # helios changed it, camera kept it
            buckets["committed"].append(entry)
        elif b == o:  # helios changed it, camera reverted to original
            buckets["reverted"].append(entry)
        else:  # helios changed it, camera stored a third value
            buckets["changed"].append(entry)
    return buckets, records
