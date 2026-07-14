import datetime
import logging
import os
import re
import struct
import sys
import time

import typer
import usb.core
import yaml
from typing_extensions import Annotated

import fuji_settings
from fuji_settings import PtpError

app = typer.Typer()

# Custom settings slots C1-C7 are exposed as plain PTP device properties in
# the same USB RAW CONV./BACKUP RESTORE mode the blob backup uses. The
# property map and encodings were reverse engineered by the filmkit project
# from Wireshark captures of Fujifilm X RAW Studio, confirmed on the X100VI:
# https://github.com/eggricesoy/filmkit/tree/9e3bbcf858b1
# (src/ptp/constants.ts, src/profile/preset-translate.ts)

PROP_PRESET_SLOT = 0xD18C
PROP_PRESET_NAME = 0xD18D
RECIPE_PROP_FIRST = 0xD18E
RECIPE_PROP_LAST = 0xD1A5

NUM_SLOTS = 7
# the official app waits after switching the active slot
SLOT_SWITCH_DELAY_S = 0.1
# a raw 0x8000 in an x10 tone field means the camera never stored a value
UNSET_SENTINEL = 0x8000

PROP_DYNAMIC_RANGE = 0xD190
PROP_FILM_SIMULATION = 0xD192
PROP_MONO_WC = 0xD193
PROP_MONO_MG = 0xD194
PROP_GRAIN = 0xD195
PROP_COLOR_CHROME = 0xD196
PROP_COLOR_CHROME_FX_BLUE = 0xD197
PROP_SMOOTH_SKIN = 0xD198
PROP_WHITE_BALANCE = 0xD199
PROP_WB_SHIFT_R = 0xD19A
PROP_WB_SHIFT_B = 0xD19B
PROP_WB_COLOR_TEMP = 0xD19C
PROP_HIGHLIGHT_TONE = 0xD19D
PROP_SHADOW_TONE = 0xD19E
PROP_COLOR = 0xD19F
PROP_SHARPNESS = 0xD1A0
PROP_HIGH_ISO_NR = 0xD1A1
PROP_CLARITY = 0xD1A2

FILM_SIMULATIONS = {
    0x01: "Provia",
    0x02: "Velvia",
    0x03: "Astia",
    0x04: "Pro Neg Hi",
    0x05: "Pro Neg Std",
    0x06: "Monochrome",
    0x07: "Monochrome+Ye",
    0x08: "Monochrome+R",
    0x09: "Monochrome+G",
    0x0A: "Sepia",
    0x0B: "Classic Chrome",
    0x0C: "Acros",
    0x0D: "Acros+Ye",
    0x0E: "Acros+R",
    0x0F: "Acros+G",
    0x10: "Eterna",
    0x11: "Classic Neg",
    0x12: "Eterna Bleach Bypass",
    0x13: "Nostalgic Neg",
    0x14: "Reala Ace",
}
MONO_SIMS = {0x06, 0x07, 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x0E, 0x0F}

# dynamic range is stored as a raw percentage except DR-Auto; observed on
# the X-T5 (a slot programmed from a published DR-Auto recipe reads 0xFFFF)
DR_AUTO_RAW = 0xFFFF

GRAIN = {
    1: "Off",  # filmkit's value, inferred rather than captured
    2: "Weak/Small",
    3: "Strong/Small",
    4: "Weak/Large",
    5: "Strong/Large",
    6: "Off",  # what the X-T5 stores; last entry wins the write lookup
}

STRENGTH3 = {1: "Off", 2: "Weak", 3: "Strong"}

WHITE_BALANCE = {
    0x0002: "Auto",
    0x0004: "Daylight",
    0x0006: "Incandescent",
    0x0008: "Underwater",
    0x8001: "Fluorescent 1",
    0x8002: "Fluorescent 2",
    0x8003: "Fluorescent 3",
    0x8006: "Shade",
    0x8007: "Color Temp",
    0x8021: "Auto Ambience Priority",
}
WB_COLOR_TEMP_MODE = 0x8007

# camera-native encoding is neither x10 nor linear
HIGH_ISO_NR_ENCODE = {
    -4: 0x8000,
    -3: 0x7000,
    -2: 0x4000,
    -1: 0x3000,
    0: 0x2000,
    1: 0x1000,
    2: 0x0000,
    3: 0x6000,
    4: 0x5000,
}
HIGH_ISO_NR_DECODE = {v: k for k, v in HIGH_ISO_NR_ENCODE.items()}

# prop id -> (yaml key, default when a recipe file omits it); values we round
# trip verbatim because the encoding is unknown or not worth modeling
PASSTHROUGH_PROPS = {
    0xD18E: ("d18e", 7),  # image size, 7 = L 3:2
    0xD18F: ("d18f", 4),  # image quality
    0xD191: ("d191", 0),  # unknown
    0xD1A3: ("d1a3", 1),  # long exposure NR, 1 = on
    0xD1A4: ("d1a4", 1),  # color space, 1 = sRGB
    0xD1A5: ("d1a5", 7),  # unknown
}
PASSTHROUGH_KEYS = {key: prop for prop, (key, _) in PASSTHROUGH_PROPS.items()}

# yaml key -> (prop id, min, max); stored on the wire as i16 value * 10
X10_FIELDS = {
    "highlight_tone": (PROP_HIGHLIGHT_TONE, -2.0, 4.0),
    "shadow_tone": (PROP_SHADOW_TONE, -2.0, 4.0),
    "color": (PROP_COLOR, -4.0, 4.0),
    "sharpness": (PROP_SHARPNESS, -4.0, 4.0),
    "clarity": (PROP_CLARITY, -5.0, 5.0),
}

RECIPE_KEYS = [
    "name",
    "film_simulation",
    "dynamic_range",
    "grain",
    "color_chrome",
    "color_chrome_fx_blue",
    "smooth_skin",
    "white_balance",
    "wb_color_temp",
    "wb_shift_r",
    "wb_shift_b",
    "highlight_tone",
    "shadow_tone",
    "color",
    "sharpness",
    "high_iso_nr",
    "clarity",
    "mono_wc",
    "mono_mg",
    "passthrough",
]


class RecipeError(Exception):
    pass


def normalize(text):
    return re.sub(r"[^a-z0-9]", "", text.lower())


def build_lookup(table):
    return {normalize(label): code for code, label in table.items()}


FILM_SIM_LOOKUP = build_lookup(FILM_SIMULATIONS)
GRAIN_LOOKUP = build_lookup(GRAIN)
STRENGTH3_LOOKUP = build_lookup(STRENGTH3)
WB_LOOKUP = build_lookup(WHITE_BALANCE)


def to_i16(raw):
    return raw - 0x10000 if raw >= 0x8000 else raw


def slugify(name):
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return slug or "unnamed"


# ---------------------------------------------------------------------------
# raw camera values <-> recipe dict


def decode_enum(table, raw):
    # unknown raw values decode to the bare integer so other bodies still
    # round trip; validate_recipe accepts integers for every enum field
    return table.get(raw, raw)


def decode_x10(raw):
    value = to_i16(raw) / 10
    return int(value) if value == int(value) else value


def decode_recipe(slot_data):
    raw = slot_data["raw"]
    recipe = {"name": slot_data["name"]}

    sim_raw = raw.get(PROP_FILM_SIMULATION)
    is_mono = sim_raw in MONO_SIMS
    if sim_raw is not None:
        recipe["film_simulation"] = decode_enum(FILM_SIMULATIONS, sim_raw)
    if PROP_DYNAMIC_RANGE in raw:
        dr = raw[PROP_DYNAMIC_RANGE]
        recipe["dynamic_range"] = "Auto" if dr == DR_AUTO_RAW else dr
    if PROP_GRAIN in raw:
        recipe["grain"] = decode_enum(GRAIN, raw[PROP_GRAIN])
    if PROP_COLOR_CHROME in raw:
        recipe["color_chrome"] = decode_enum(STRENGTH3, raw[PROP_COLOR_CHROME])
    if PROP_COLOR_CHROME_FX_BLUE in raw:
        recipe["color_chrome_fx_blue"] = decode_enum(
            STRENGTH3, raw[PROP_COLOR_CHROME_FX_BLUE]
        )
    if PROP_SMOOTH_SKIN in raw:
        recipe["smooth_skin"] = decode_enum(STRENGTH3, raw[PROP_SMOOTH_SKIN])

    if PROP_WHITE_BALANCE in raw:
        recipe["white_balance"] = decode_enum(WHITE_BALANCE, raw[PROP_WHITE_BALANCE])
        if raw[PROP_WHITE_BALANCE] == WB_COLOR_TEMP_MODE and raw.get(
            PROP_WB_COLOR_TEMP, 0
        ):
            recipe["wb_color_temp"] = raw[PROP_WB_COLOR_TEMP]
    if PROP_WB_SHIFT_R in raw:
        recipe["wb_shift_r"] = to_i16(raw[PROP_WB_SHIFT_R])
    if PROP_WB_SHIFT_B in raw:
        recipe["wb_shift_b"] = to_i16(raw[PROP_WB_SHIFT_B])

    for key, (prop, _, _) in X10_FIELDS.items():
        if key == "color" and is_mono:
            continue
        if prop in raw and raw[prop] != UNSET_SENTINEL:
            recipe[key] = decode_x10(raw[prop])

    if PROP_HIGH_ISO_NR in raw:
        nr = HIGH_ISO_NR_DECODE.get(raw[PROP_HIGH_ISO_NR])
        if nr is not None:
            recipe["high_iso_nr"] = nr
        else:
            logging.debug(
                f"unknown high ISO NR encoding 0x{raw[PROP_HIGH_ISO_NR]:04X}, omitting"
            )

    if is_mono:
        for key, prop in (("mono_wc", PROP_MONO_WC), ("mono_mg", PROP_MONO_MG)):
            if prop in raw and raw[prop] != UNSET_SENTINEL:
                value = to_i16(raw[prop])
                if value % 10 == 0:
                    recipe[key] = value // 10
                else:
                    logging.debug(f"unexpected {key} raw value {value}, omitting")

    passthrough = {}
    for prop, (key, _) in PASSTHROUGH_PROPS.items():
        if prop in raw:
            passthrough[key] = raw[prop]
    if passthrough:
        recipe["passthrough"] = passthrough

    return recipe


def encode_enum(table, lookup, value, key):
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    code = lookup.get(normalize(str(value)))
    if code is None:
        raise RecipeError(f"{key}: unknown value {value!r}")
    return code


def encode_x10(value):
    return int(round(float(value) * 10)) & 0xFFFF


def encode_dynamic_range(value):
    if isinstance(value, str):
        if normalize(value) in ("auto", "drauto"):
            return DR_AUTO_RAW
        raise RecipeError(f"dynamic_range: unknown value {value!r}")
    return value


def encode_recipe(recipe):
    """Return the ordered (prop id, u16 value) write list for a recipe.

    Order mirrors the X RAW Studio captures: ascending prop ids except the
    WB color temperature, which the camera only accepts immediately after
    the WB mode. Conditional fields the camera rejects are omitted.
    """
    sim = encode_enum(
        FILM_SIMULATIONS, FILM_SIM_LOOKUP, recipe["film_simulation"], "film_simulation"
    )
    is_mono = sim in MONO_SIMS
    passthrough = recipe.get("passthrough", {})

    def pt(prop):
        key, default = PASSTHROUGH_PROPS[prop]
        return passthrough.get(key, default)

    props = [
        (0xD18E, pt(0xD18E)),
        (0xD18F, pt(0xD18F)),
        (PROP_DYNAMIC_RANGE, encode_dynamic_range(recipe.get("dynamic_range", 100))),
        (0xD191, pt(0xD191)),
        (PROP_FILM_SIMULATION, sim),
    ]

    # the camera rejects a monochromatic color of 0, absent means do not write
    if is_mono:
        for key, prop in (("mono_wc", PROP_MONO_WC), ("mono_mg", PROP_MONO_MG)):
            value = recipe.get(key, 0)
            if value:
                props.append((prop, encode_x10(value)))

    props.append(
        (
            PROP_GRAIN,
            encode_enum(GRAIN, GRAIN_LOOKUP, recipe.get("grain", "Off"), "grain"),
        )
    )
    for key, prop in (
        ("color_chrome", PROP_COLOR_CHROME),
        ("color_chrome_fx_blue", PROP_COLOR_CHROME_FX_BLUE),
        ("smooth_skin", PROP_SMOOTH_SKIN),
    ):
        props.append(
            (
                prop,
                encode_enum(STRENGTH3, STRENGTH3_LOOKUP, recipe.get(key, "Off"), key),
            )
        )

    wb = encode_enum(
        WHITE_BALANCE, WB_LOOKUP, recipe.get("white_balance", "Auto"), "white_balance"
    )
    props.append((PROP_WHITE_BALANCE, wb))
    # only valid right after the WB mode, and only in color temperature mode
    if wb == WB_COLOR_TEMP_MODE:
        props.append((PROP_WB_COLOR_TEMP, recipe["wb_color_temp"]))
    props.append((PROP_WB_SHIFT_R, recipe.get("wb_shift_r", 0) & 0xFFFF))
    props.append((PROP_WB_SHIFT_B, recipe.get("wb_shift_b", 0) & 0xFFFF))

    # absent tone fields write 0 so the slot ends in a deterministic state
    props.append((PROP_HIGHLIGHT_TONE, encode_x10(recipe.get("highlight_tone", 0))))
    props.append((PROP_SHADOW_TONE, encode_x10(recipe.get("shadow_tone", 0))))
    if not is_mono:
        props.append((PROP_COLOR, encode_x10(recipe.get("color", 0))))
    props.append((PROP_SHARPNESS, encode_x10(recipe.get("sharpness", 0))))
    props.append((PROP_HIGH_ISO_NR, HIGH_ISO_NR_ENCODE[recipe.get("high_iso_nr", 0)]))
    props.append((PROP_CLARITY, encode_x10(recipe.get("clarity", 0))))

    for prop in (0xD1A3, 0xD1A4, 0xD1A5):
        props.append((prop, pt(prop)))

    return props


def validate_recipe(recipe, source):
    def fail(message):
        raise RecipeError(f"{source}: {message}")

    if not isinstance(recipe, dict):
        fail("expected a mapping at the top level")

    unknown = set(recipe) - set(RECIPE_KEYS)
    if unknown:
        fail(f"unknown keys: {', '.join(sorted(unknown))}")

    # yaml 1.1 parses an unquoted Off as boolean False; map it back
    for key in (
        "grain",
        "color_chrome",
        "color_chrome_fx_blue",
        "smooth_skin",
    ):
        if recipe.get(key) is False:
            recipe[key] = "Off"

    if not recipe.get("name"):
        fail("name is required")
    if not isinstance(recipe["name"], str):
        fail("name must be a string")
    if "film_simulation" not in recipe:
        fail("film_simulation is required")

    sim = encode_enum(
        FILM_SIMULATIONS, FILM_SIM_LOOKUP, recipe["film_simulation"], "film_simulation"
    )
    is_mono = sim in MONO_SIMS

    if "dynamic_range" in recipe:
        dr = recipe["dynamic_range"]
        if isinstance(dr, str) and normalize(dr) in ("auto", "drauto"):
            recipe["dynamic_range"] = "Auto"
        elif dr not in (100, 200, 400, DR_AUTO_RAW):
            fail('dynamic_range must be 100, 200, 400, or "Auto"')

    for key, table, lookup in (
        ("grain", GRAIN, GRAIN_LOOKUP),
        ("color_chrome", STRENGTH3, STRENGTH3_LOOKUP),
        ("color_chrome_fx_blue", STRENGTH3, STRENGTH3_LOOKUP),
        ("smooth_skin", STRENGTH3, STRENGTH3_LOOKUP),
        ("white_balance", WHITE_BALANCE, WB_LOOKUP),
    ):
        if key in recipe:
            encode_enum(table, lookup, recipe[key], key)

    wb = encode_enum(
        WHITE_BALANCE, WB_LOOKUP, recipe.get("white_balance", "Auto"), "white_balance"
    )
    if wb == WB_COLOR_TEMP_MODE:
        temp = recipe.get("wb_color_temp")
        if not isinstance(temp, int) or not 2500 <= temp <= 10000:
            fail("wb_color_temp (2500-10000) is required with Color Temp white balance")
    elif "wb_color_temp" in recipe:
        fail("wb_color_temp is only valid with Color Temp white balance")

    for key in ("wb_shift_r", "wb_shift_b"):
        value = recipe.get(key, 0)
        if not isinstance(value, int) or not -9 <= value <= 9:
            fail(f"{key} must be an integer between -9 and 9")

    for key, (_, low, high) in X10_FIELDS.items():
        if key not in recipe:
            continue
        value = recipe[key]
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            fail(f"{key} must be a number")
        if not low <= value <= high:
            fail(f"{key} must be between {low:+g} and {high:+g}")
        if round(value * 2) != value * 2:
            fail(f"{key} must be a multiple of 0.5")
    if is_mono and "color" in recipe:
        fail("color does not apply to monochrome film simulations, remove it")

    nr = recipe.get("high_iso_nr", 0)
    if nr not in HIGH_ISO_NR_ENCODE:
        fail("high_iso_nr must be an integer between -4 and 4")

    for key in ("mono_wc", "mono_mg"):
        value = recipe.get(key, 0)
        if not isinstance(value, int) or not -9 <= value <= 9:
            fail(f"{key} must be an integer between -9 and 9")
        if value and not is_mono:
            fail(f"{key} only applies to monochrome film simulations")

    passthrough = recipe.get("passthrough", {})
    if not isinstance(passthrough, dict):
        fail("passthrough must be a mapping")
    for key, value in passthrough.items():
        if key not in PASSTHROUGH_KEYS:
            fail(f"passthrough.{key} is not a known field")
        if not isinstance(value, int) or not 0 <= value <= 0xFFFF:
            fail(f"passthrough.{key} must be an integer between 0 and 65535")

    return recipe


def summarize(recipe):
    parts = [str(recipe.get("film_simulation", "?"))]
    if "dynamic_range" in recipe:
        dr = recipe["dynamic_range"]
        parts.append("DR Auto" if dr == "Auto" else f"DR{dr}")
    grain = recipe.get("grain", "Off")
    if grain != "Off":
        parts.append(f"grain {grain}")
    for key, label in (
        ("color_chrome", "CC"),
        ("color_chrome_fx_blue", "CCB"),
        ("smooth_skin", "skin"),
    ):
        value = recipe.get(key, "Off")
        if value != "Off":
            parts.append(f"{label} {value}")
    wb = str(recipe.get("white_balance", "Auto"))
    if "wb_color_temp" in recipe:
        wb += f" {recipe['wb_color_temp']}K"
    shift_r = recipe.get("wb_shift_r", 0)
    shift_b = recipe.get("wb_shift_b", 0)
    if shift_r or shift_b:
        wb += f" R{shift_r:+d} B{shift_b:+d}"
    parts.append(f"WB {wb}")
    for key, label in (
        ("highlight_tone", "H"),
        ("shadow_tone", "S"),
        ("color", "color"),
        ("sharpness", "sharp"),
        ("clarity", "clarity"),
        ("high_iso_nr", "NR"),
        ("mono_wc", "WC"),
        ("mono_mg", "MG"),
    ):
        value = recipe.get(key, 0)
        if value:
            parts.append(f"{label}{value:+g}")
    return ", ".join(parts)


# ---------------------------------------------------------------------------
# recipe files


def recipe_to_yaml(recipe, comments=()):
    header = ["# Fujifilm film recipe for helios fuji-recipes restore"]
    for comment in comments:
        header.append(f"# {comment}")
    ordered = {key: recipe[key] for key in RECIPE_KEYS if key in recipe}
    body = yaml.safe_dump(ordered, sort_keys=False, default_flow_style=False)
    return "\n".join(header) + "\n" + body


def load_recipe_file(path):
    try:
        with open(path, "r") as f:
            recipe = yaml.safe_load(f)
    except OSError as e:
        raise RecipeError(f"could not read {path}: {e}")
    except yaml.YAMLError as e:
        raise RecipeError(f"{path}: not valid YAML ({e})")
    return validate_recipe(recipe, path)


# ---------------------------------------------------------------------------
# fujixweekly text import

# fujixweekly.com spells some values differently than the camera menus
SIM_ALIASES = {
    "proviastandard": 0x01,
    "standard": 0x01,
    "velviavivid": 0x02,
    "vivid": 0x02,
    "astiasoft": 0x03,
    "soft": 0x03,
    "pronegativehi": 0x04,
    "proneghi": 0x04,
    "pronegativestd": 0x05,
    "pronegstd": 0x05,
    "monochromeyellow": 0x07,
    "monochromered": 0x08,
    "monochromegreen": 0x09,
    "monoye": 0x07,
    "monor": 0x08,
    "monog": 0x09,
    "classicnegative": 0x11,
    "eternacinema": 0x10,
    "cinema": 0x10,
    "eternableachbypass": 0x12,
    "bleachbypass": 0x12,
    "nostalgicnegative": 0x13,
    "acrosyellow": 0x0D,
    "acrosred": 0x0E,
    "acrosgreen": 0x0F,
    "acrosy": 0x0D,
    "acrosr": 0x0E,
    "acrosg": 0x0F,
    "realaace": 0x14,
}

WB_ALIASES = {
    "auto": 0x0002,
    "awb": 0x0002,
    "autoambiencepriority": 0x8021,
    "ambiencepriority": 0x8021,
    "daylight": 0x0004,
    "sunny": 0x0004,
    "fine": 0x0004,
    "shade": 0x8006,
    "cloudy": 0x8006,
    "incandescent": 0x0006,
    "tungsten": 0x0006,
    "underwater": 0x0008,
    "fluorescent": 0x8001,
    "fluorescent1": 0x8001,
    "fluorescent2": 0x8002,
    "fluorescent3": 0x8003,
    "kelvin": WB_COLOR_TEMP_MODE,
    "colortemperature": WB_COLOR_TEMP_MODE,
    "colourtemperature": WB_COLOR_TEMP_MODE,
}

NUMBER_RE = re.compile(r"[+-]?\d+(?:\.\d+)?")


def parse_number(value):
    match = NUMBER_RE.search(value)
    if not match:
        return None
    number = float(match.group())
    return int(number) if number == int(number) else number


def parse_film_sim_value(value):
    code = FILM_SIM_LOOKUP.get(normalize(value)) or SIM_ALIASES.get(normalize(value))
    if code is None:
        return None
    return {"film_simulation": FILM_SIMULATIONS[code]}


def parse_dynamic_range_value(value):
    if "auto" in value.lower():
        return {"dynamic_range": "Auto"}
    number = parse_number(value)
    if number in (100, 200, 400):
        return {"dynamic_range": int(number)}
    return None


def parse_grain_value(value):
    lowered = value.lower()
    if "off" in lowered:
        return {"grain": "Off"}
    strength = (
        "Weak" if "weak" in lowered else "Strong" if "strong" in lowered else None
    )
    if strength is None:
        return None
    # older recipes predate the size option; small matches those cameras
    size = "Large" if "large" in lowered else "Small"
    return {"grain": f"{strength}/{size}"}


def parse_strength3_value(value):
    lowered = value.lower()
    if "off" in lowered or normalize(value) in ("no", "none", "0"):
        return "Off"
    if "weak" in lowered:
        return "Weak"
    if "strong" in lowered:
        return "Strong"
    return None


def parse_wb_value(value):
    fields = {}
    red = re.search(r"([+-]?\d+)\s*(?:red|r\b)", value, re.IGNORECASE)
    blue = re.search(r"([+-]?\d+)\s*(?:blue|b\b)", value, re.IGNORECASE)
    if red:
        fields["wb_shift_r"] = int(red.group(1))
    if blue:
        fields["wb_shift_b"] = int(blue.group(1))

    kelvin = re.search(r"(\d{4,5})\s*k\b", value, re.IGNORECASE)
    if kelvin:
        fields["white_balance"] = WHITE_BALANCE[WB_COLOR_TEMP_MODE]
        fields["wb_color_temp"] = int(kelvin.group(1))
        return fields

    mode_text = re.split(r"[,;]", value)[0]
    mode_text = re.sub(
        r"[+-]?\d+\s*(?:red|blue|r\b|b\b)", "", mode_text, flags=re.IGNORECASE
    )
    code = WB_ALIASES.get(normalize(mode_text)) or WB_LOOKUP.get(normalize(mode_text))
    if code is None:
        return fields if fields else None
    fields["white_balance"] = WHITE_BALANCE[code]
    return fields


def parse_mono_color_value(value):
    fields = {}
    wc = re.search(r"wc\s*[:=]?\s*([+-]?\d+)", value, re.IGNORECASE)
    mg = re.search(r"mg\s*[:=]?\s*([+-]?\d+)", value, re.IGNORECASE)
    if wc:
        fields["mono_wc"] = int(wc.group(1))
    if mg:
        fields["mono_mg"] = int(mg.group(1))
    if not fields:
        number = parse_number(value)
        if number is not None:
            fields["mono_wc"] = int(number)
    return fields or None


def make_number_parser(key, integer=False):
    def parse(value):
        number = parse_number(value)
        if number is None:
            return None
        return {key: int(number) if integer else number}

    return parse


# normalized label -> value parser; None marks shooting parameters that are
# preserved as comments because slots cannot store them
LABEL_PARSERS = {
    "filmsimulation": parse_film_sim_value,
    "filmsim": parse_film_sim_value,
    "dynamicrange": parse_dynamic_range_value,
    "graineffect": parse_grain_value,
    "grain": parse_grain_value,
    "colorchromeeffect": lambda v: _strength3_field("color_chrome", v),
    "colorchrome": lambda v: _strength3_field("color_chrome", v),
    "colorchromefxblue": lambda v: _strength3_field("color_chrome_fx_blue", v),
    "colorchromeeffectblue": lambda v: _strength3_field("color_chrome_fx_blue", v),
    "colorchromeblue": lambda v: _strength3_field("color_chrome_fx_blue", v),
    "smoothskineffect": lambda v: _strength3_field("smooth_skin", v),
    "smoothskin": lambda v: _strength3_field("smooth_skin", v),
    "whitebalance": parse_wb_value,
    "wb": parse_wb_value,
    "highlight": make_number_parser("highlight_tone"),
    "highlighttone": make_number_parser("highlight_tone"),
    "shadow": make_number_parser("shadow_tone"),
    "shadowtone": make_number_parser("shadow_tone"),
    "color": make_number_parser("color"),
    "sharpness": make_number_parser("sharpness"),
    "sharpening": make_number_parser("sharpness"),
    "highisonr": make_number_parser("high_iso_nr", integer=True),
    "noisereduction": make_number_parser("high_iso_nr", integer=True),
    "nr": make_number_parser("high_iso_nr", integer=True),
    "clarity": make_number_parser("clarity"),
    "monochromaticcolor": parse_mono_color_value,
    "toning": parse_mono_color_value,
    "iso": None,
    "exposurecompensation": None,
}


def _strength3_field(key, value):
    strength = parse_strength3_value(value)
    return {key: strength} if strength else None


def parse_recipe_text(text):
    """Fuzzily parse pasted fujixweekly recipe text into a partial recipe.

    Pass 1 handles labeled lines; pass 2 tries the film simulation on
    unlabeled lines, and the first line that matches nothing becomes the
    recipe name (recipe posts start with a title).
    """
    recipe = {}
    report = {"recognized": [], "ignored": [], "unrecognized": [], "comments": []}

    for line in text.splitlines():
        line = line.strip().strip("*-# \t")
        if not line:
            continue

        label, _, value = line.partition(":")
        known_label = value and normalize(label) in LABEL_PARSERS
        if known_label:
            parser = LABEL_PARSERS[normalize(label)]
            if parser is None:
                # a known shooting parameter that slots cannot store
                report["ignored"].append(line)
                report["comments"].append(line)
                continue
            fields = parser(value.strip())
            if fields:
                recipe.update(fields)
                report["recognized"].append((line, sorted(fields)))
            else:
                report["unrecognized"].append(line)
            continue

        # unlabeled line: a bare film simulation, or the recipe title
        fields = parse_film_sim_value(line)
        if fields and "film_simulation" not in recipe:
            recipe.update(fields)
            report["recognized"].append((line, sorted(fields)))
        elif "name" not in recipe:
            recipe["name"] = line
            report["recognized"].append((line, ["name"]))
        else:
            report["unrecognized"].append(line)

    return recipe, report


@app.command("import")
def import_(
    ctx: typer.Context,
    file: Annotated[
        str, typer.Argument(help="Text file with a pasted recipe, or - for stdin")
    ],
    output: Annotated[
        str,
        typer.Option(
            help="Output path, defaults to <recipe-name>.yaml under <library>/settings/recipes"
        ),
    ] = None,
    name: Annotated[str, typer.Option(help="Override the recipe name")] = None,
):
    """Convert pasted fujixweekly recipe text into a recipe file."""
    try:
        text = sys.stdin.read() if file == "-" else open(file, "r").read()
    except OSError as e:
        logging.error(f"could not read {file}: {e}")
        sys.exit(1)

    recipe, report = parse_recipe_text(text)
    if name:
        recipe["name"] = name

    for line, fields in report["recognized"]:
        logging.info(f"parsed {', '.join(fields)}: {line}")
    for line in report["ignored"]:
        logging.info(f"kept as comment (not stored in camera slots): {line}")
    for line in report["unrecognized"]:
        logging.warning(f"could not parse: {line}")

    try:
        validate_recipe(recipe, file)
    except RecipeError as e:
        logging.error(str(e))
        sys.exit(1)

    if output:
        path = output
    else:
        recipe_dir = fuji_settings.settings_dir(ctx, "recipes")
        os.makedirs(recipe_dir, exist_ok=True)
        path = os.path.join(recipe_dir, f"{slugify(recipe['name'])}.yaml")
    if os.path.exists(path):
        logging.error(f"refusing to overwrite {path}; move it or pass --output")
        sys.exit(1)

    comments = [f"imported from pasted text on {datetime.date.today().isoformat()}"]
    comments.extend(report["comments"])
    with open(path, "w") as f:
        f.write(recipe_to_yaml(recipe, comments))
    logging.info(f"wrote {path}")


# ---------------------------------------------------------------------------
# camera access


def parse_u16(prop, data):
    if data is None or len(data) == 0:
        raise RuntimeError(f"camera sent no data for property 0x{prop:04X}")
    if len(data) >= 4:
        return struct.unpack_from("<I", data)[0] & 0xFFFF
    if len(data) >= 2:
        return struct.unpack_from("<H", data)[0]
    return data[0]


def require_recipe_support(ptp, model, force):
    if PROP_PRESET_SLOT in ptp.supported_props:
        return
    if force:
        logging.warning(
            "camera does not advertise recipe properties, continuing because of --force"
        )
        return
    logging.error(
        f"{model} does not report film recipe support (property 0x{PROP_PRESET_SLOT:04X} "
        "missing from DeviceInfo); this needs an X-Processor 5 era body, or rerun "
        "with --force to try anyway"
    )
    sys.exit(1)


def select_slot(ptp, slot):
    ptp.set_prop(PROP_PRESET_SLOT, struct.pack("<H", slot))
    time.sleep(SLOT_SWITCH_DELAY_S)


def read_slot(ptp, slot):
    select_slot(ptp, slot)
    name, _ = fuji_settings.read_ptp_string(ptp.get_prop(PROP_PRESET_NAME), 0)
    raw = {}
    for prop in range(RECIPE_PROP_FIRST, RECIPE_PROP_LAST + 1):
        try:
            raw[prop] = parse_u16(prop, ptp.get_prop(prop))
        except (PtpError, RuntimeError) as e:
            logging.debug(f"slot {slot}: could not read 0x{prop:04X} ({e})")
    return {"slot": slot, "name": name.strip(), "raw": raw}


def write_slot(ptp, slot, recipe, name):
    props = encode_recipe(recipe)
    warnings = []

    select_slot(ptp, slot)
    ptp.set_prop(PROP_PRESET_NAME, fuji_settings.encode_ptp_string(name))

    written = []
    rejected = []
    for prop, value in props:
        try:
            ptp.set_prop(prop, struct.pack("<H", value & 0xFFFF))
            written.append((prop, value & 0xFFFF))
        except PtpError as e:
            rejected.append((prop, value & 0xFFFF, e))

    # the X-T5 rejects some writes whose value the slot already holds
    # (observed: clarity 0x0000 comes back PTP 0x201C); only warn when the
    # slot actually ends up different from the recipe
    for prop, value, error in rejected:
        try:
            actual = parse_u16(prop, ptp.get_prop(prop))
        except (PtpError, RuntimeError):
            actual = None
        if actual == value:
            logging.debug(
                f"camera rejected 0x{prop:04X}=0x{value:04X} (PTP {error}) "
                "but the slot already holds that value"
            )
        elif prop == PROP_CLARITY:
            # the X-T5 rejects every clarity write (any value, any payload
            # size) with PTP 0x201C; reads work fine
            warnings.append(
                f"clarity {decode_x10(value):+g} not written (PTP {error}); "
                "the camera rejects clarity over USB, set it by hand in "
                "IMAGE QUALITY SETTING > CLARITY and resave the slot"
            )
        else:
            warnings.append(f"camera rejected 0x{prop:04X}=0x{value:04X} (PTP {error})")

    read_back, _ = fuji_settings.read_ptp_string(ptp.get_prop(PROP_PRESET_NAME), 0)
    if read_back.strip() != name:
        warnings.append(
            f"name verify mismatch: wrote {name!r}, read {read_back.strip()!r} "
            "(the camera may have truncated it)"
        )
    for prop, value in written:
        try:
            actual = parse_u16(prop, ptp.get_prop(prop))
        except (PtpError, RuntimeError) as e:
            warnings.append(f"could not verify 0x{prop:04X} ({e})")
            continue
        if actual != value:
            warnings.append(
                f"verify mismatch on 0x{prop:04X}: wrote 0x{value:04X}, read 0x{actual:04X}"
            )
    return warnings


def with_camera(device, force, fn):
    """Run fn(ptp, model) with the usual connect and error handling.

    The camera's active custom slot is saved up front and restored afterward
    so scans and writes to other slots leave the camera where the user had it.
    """
    ptp = None
    try:
        ptp, model = fuji_settings.open_camera(device, force=force)
        require_recipe_support(ptp, model, force)
        original_slot = None
        try:
            original_slot = parse_u16(PROP_PRESET_SLOT, ptp.get_prop(PROP_PRESET_SLOT))
        except (PtpError, RuntimeError) as e:
            logging.debug(f"could not read the active slot ({e})")
        try:
            return fn(ptp, model)
        finally:
            if original_slot is not None and 1 <= original_slot <= NUM_SLOTS:
                try:
                    select_slot(ptp, original_slot)
                except (PtpError, RuntimeError, usb.core.USBError):
                    logging.debug("could not restore the active slot")
    except usb.core.USBError as e:
        logging.error(f"USB error talking to the camera ({e}); reconnect and retry")
        sys.exit(1)
    except PtpError as e:
        logging.error(f"camera returned PTP error {e}")
        sys.exit(1)
    except RuntimeError as e:
        logging.error(f"{e}; reconnect and retry")
        sys.exit(1)
    finally:
        if ptp is not None:
            ptp.close()


def parse_slots(slots):
    if not slots:
        return list(range(1, NUM_SLOTS + 1))
    try:
        parsed = sorted({int(s) for s in slots.split(",")})
    except ValueError:
        logging.error(f"--slots must look like 1,3,7 (got {slots!r})")
        sys.exit(1)
    if any(s < 1 or s > NUM_SLOTS for s in parsed):
        logging.error(f"--slots values must be between 1 and {NUM_SLOTS}")
        sys.exit(1)
    return parsed


# ---------------------------------------------------------------------------
# commands


@app.command("list")
def list_(
    ctx: typer.Context,
    dump_raw: Annotated[
        bool,
        typer.Option("--dump-raw", help="Also print raw property values per slot"),
    ] = False,
    device: Annotated[
        int, typer.Option(help="Camera index when several are connected")
    ] = None,
    force: Annotated[
        bool, typer.Option("--force", help="Skip the USB mode and support checks")
    ] = False,
):
    """Show the recipes stored in the camera's custom settings slots."""

    def run(ptp, model):
        for slot in range(1, NUM_SLOTS + 1):
            data = read_slot(ptp, slot)
            recipe = decode_recipe(data)
            name = data["name"] or "(unnamed)"
            print(f"C{slot}  {name:<24} {summarize(recipe)}")
            if dump_raw:
                raw = " ".join(
                    f"0x{prop:04X}=0x{value:04X}"
                    for prop, value in sorted(data["raw"].items())
                )
                print(f"    {raw}")

    with_camera(device, force, run)


@app.command()
def backup(
    ctx: typer.Context,
    dir: Annotated[
        str,
        typer.Option(
            help="Directory to write recipe files into, defaults to <library>/settings/recipes"
        ),
    ] = None,
    slots: Annotated[
        str, typer.Option(help="Comma separated slot numbers, defaults to all")
    ] = None,
    device: Annotated[
        int, typer.Option(help="Camera index when several are connected")
    ] = None,
    force: Annotated[
        bool, typer.Option("--force", help="Skip the USB mode and support checks")
    ] = False,
):
    """Save the camera's custom settings slots as recipe files."""
    wanted = parse_slots(slots)
    if dir is None:
        dir = fuji_settings.settings_dir(ctx, "recipes")

    def run(ptp, model):
        recipes = []
        for slot in wanted:
            data = read_slot(ptp, slot)
            recipes.append((slot, data["name"], decode_recipe(data)))

        # resolve every path before writing anything so a refused overwrite
        # never leaves a half written set
        targets = []
        for slot, name, recipe in recipes:
            filename = f"c{slot}-{slugify(name)}.yaml" if name else f"c{slot}.yaml"
            targets.append((os.path.join(dir, filename), slot, recipe))
        existing = [path for path, _, _ in targets if os.path.exists(path)]
        if existing:
            logging.error(
                f"refusing to overwrite {', '.join(existing)}; move them or use --dir"
            )
            sys.exit(1)

        os.makedirs(dir, exist_ok=True)
        today = datetime.date.today().isoformat()
        for path, slot, recipe in targets:
            comments = [f"camera: {model}, slot: C{slot}, date: {today}"]
            with open(path, "w") as f:
                f.write(recipe_to_yaml(recipe, comments))
            logging.info(f"wrote {path}")
        logging.info(f"backed up {len(targets)} recipes from {model}")

    with_camera(device, force, run)


def map_recipe_dir(dir):
    pattern = re.compile(r"^c([1-7])[.-]")
    mapping = {}
    try:
        entries = sorted(os.listdir(dir))
    except OSError as e:
        logging.error(f"could not read {dir}: {e}")
        sys.exit(1)
    for entry in entries:
        if not entry.endswith(".yaml"):
            continue
        match = pattern.match(entry)
        if not match:
            # imported recipes have no slot prefix until they are assigned one
            logging.info(f"skipping {entry} (no c1- to c7- slot prefix)")
            continue
        slot = int(match.group(1))
        if slot in mapping:
            logging.error(f"both {mapping[slot]} and {entry} map to slot C{slot}")
            sys.exit(1)
        mapping[slot] = entry
    if not mapping:
        logging.error(f"no c1- to c7- prefixed .yaml recipe files found in {dir}")
        sys.exit(1)
    return {slot: os.path.join(dir, entry) for slot, entry in mapping.items()}


@app.command()
def restore(
    ctx: typer.Context,
    file: Annotated[str, typer.Argument(help="Recipe file to restore")] = None,
    slot: Annotated[
        int, typer.Option(min=1, max=NUM_SLOTS, help="Target slot (1-7)")
    ] = None,
    dir: Annotated[
        str,
        typer.Option(
            help="Restore a whole directory, mapping c1-*.yaml to C1; used by default "
            "with <library>/settings/recipes when no FILE is given"
        ),
    ] = None,
    name: Annotated[
        str, typer.Option(help="Override the recipe name stored in the camera")
    ] = None,
    yes: Annotated[
        bool, typer.Option("--yes", help="Skip the confirmation prompt")
    ] = False,
    device: Annotated[
        int, typer.Option(help="Camera index when several are connected")
    ] = None,
    force: Annotated[
        bool, typer.Option("--force", help="Skip the USB mode and support checks")
    ] = False,
):
    """Write recipe files into the camera's custom settings slots."""
    if file is not None and dir is not None:
        logging.error("pass either a recipe FILE with --slot, or --dir, not both")
        sys.exit(1)
    if file is not None and slot is None:
        logging.error("--slot is required when restoring a single file")
        sys.exit(1)
    if file is None and dir is None:
        dir = fuji_settings.settings_dir(ctx, "recipes")
        logging.info(f"restoring from {dir}")

    # parse and validate everything before touching the camera
    try:
        if file is not None:
            plan = [(slot, file, validate_recipe(load_recipe_file(file), file))]
        else:
            plan = [
                (s, path, load_recipe_file(path))
                for s, path in sorted(map_recipe_dir(dir).items())
            ]
    except RecipeError as e:
        logging.error(str(e))
        sys.exit(1)

    def run(ptp, model):
        print(f"Connected camera: {model}")
        for target_slot, path, recipe in plan:
            recipe_name = name if (name and file is not None) else recipe["name"]
            print(f"C{target_slot}  {recipe_name} ({os.path.basename(path)})")
            print(f"    {summarize(recipe)}")
        print(
            "Hint: take a full settings backup first with 'helios fuji-settings backup'."
        )
        if not yes and not typer.confirm(f"Write {len(plan)} recipe(s) to the camera?"):
            logging.info("aborted, nothing was sent")
            sys.exit(0)

        total_warnings = 0
        for target_slot, path, recipe in plan:
            recipe_name = name if (name and file is not None) else recipe["name"]
            warnings = write_slot(ptp, target_slot, recipe, recipe_name)
            for warning in warnings:
                logging.warning(f"C{target_slot}: {warning}")
            total_warnings += len(warnings)
            logging.info(f"restored C{target_slot} from {path}")
        if total_warnings:
            logging.info(
                f"done with {total_warnings} warnings; check the slots on the camera"
            )

    with_camera(device, force, run)


if __name__ == "__main__":
    app()
