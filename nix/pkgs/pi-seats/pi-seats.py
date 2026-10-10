"""Resolve and check pi's model seats.

  pi-seats get VAR             the effective value: the caller's env when
                               non-empty, else the seats file, else nothing
  pi-seats list                VAR<TAB>value for each seat in the seats file
  pi-seats check --deploy      the seats file's values; an id missing from
                               the catalog fails
  pi-seats check --start [--require VAR]...
                               the effective values; an id missing from the
                               catalog only warns
  pi-seats source              the sops file this host's seats and catalog
                               are edited in, or nothing

A seat is an env var holding `provider/id[:level]`. The seats file holds
`VAR=value` lines and is parsed, never sourced. Messages name a variable or
a provider, never a value, because they land in deploy logs and agent
transcripts, and each one says what to change.
"""

import json
import os
import re
import sys
from pathlib import Path

# Empty when the host has no seats file. A leading ~ is the caller's $HOME.
SEATS_FILE = "@seatsFile@"
# Empty when the host keeps no trust list, and then no seat's provider is
# checked.
TRUSTED = [p for p in "@trustedProviders@".split(",") if p]
# Repo path of the sops file holding pi_seats and pi_models_json, for the
# fix-it lines. Empty when the host didn't name one.
SOURCE = "@secretsSource@"
AGENT_DIR = Path(os.environ.get("PI_CODING_AGENT_DIR", Path.home() / ".pi/agent"))

LEVELS = ("off", "minimal", "low", "medium", "high", "xhigh", "max")
FIXED = (
    "PI_SESSION_MODEL",
    "PI_ADVISOR_MODEL",
    "PI_SPAWN_MODEL",
    "PI_DELEGATE_MODEL",
    "PI_CLASSIFY_MODEL",
)
SEAT_SHAPE = re.compile(
    r"PI_(SESSION|ADVISOR|SPAWN|DELEGATE|CLASSIFY)_MODEL|PI_AGENT_MODEL_[A-Z0-9_]+"
)
LINE = re.compile(r"([A-Z][A-Z0-9_]*)=(\S+)")
AGENT_NAME = re.compile(r"[A-Za-z0-9_]+")


class Unreadable(Exception):
    pass


def seats_path():
    return Path(SEATS_FILE).expanduser() if SEATS_FILE else None


def read_lines():
    """The well-formed lines as (number, VAR, value), and the numbers of the
    rest. A missing file has neither; one that exists but can't be read
    raises."""
    path = seats_path()
    if path is None:
        return [], []
    try:
        text = path.read_text()
    except FileNotFoundError:
        return [], []
    except (OSError, ValueError) as e:
        raise Unreadable(f"{path}: cannot read it ({type(e).__name__})")
    good, bad = [], []
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        m = LINE.fullmatch(line)
        if m:
            good.append((n, m[1], m[2]))
        else:
            bad.append(n)
    return good, bad


def file_seats():
    """VAR -> value; a var set twice keeps its last value."""
    good, _bad = read_lines()
    return {var: value for _n, var, value in good}


def parse(value):
    """(provider, id, level or None), or None when the value isn't one.

    pi's own split: the provider ends at the first `/`, and a suffix after
    the last `:` is a level only when it names one.
    """
    provider, slash, rest = value.partition("/")
    model, colon, level = rest.rpartition(":")
    if not (colon and level in LEVELS):
        model, level = rest, None
    if not (slash and provider and model):
        return None
    return provider, model, level


def frontmatter(text):
    """The top-level `key: value` pairs between the leading `---` lines."""
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        return {}
    fields = {}
    for line in lines[1:]:
        if line == "---":
            return fields
        key, colon, value = line.partition(":")
        if colon and not line[:1].isspace():
            fields[key.strip()] = value.strip().strip("\"'")
    return {}


def agents():
    """(file name, frontmatter) for each agent task.ts registers: one whose
    frontmatter has a name and a description."""
    found = []
    for path in sorted((AGENT_DIR / "agents").glob("*.md")):
        try:
            fields = frontmatter(path.read_text())
        except (OSError, ValueError):
            continue
        if fields.get("name") and fields.get("description"):
            found.append((path.name, fields))
    return found


def load_catalog(errors, needed):
    """models.json, or {} with an error saying why there is none. A missing
    catalog is an error only when some seat needs one."""
    path = AGENT_DIR / "models.json"
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        if not needed:
            return {}
        if path.is_symlink():
            errors.append(
                f"{path} links to {os.readlink(path)}, which does not exist. "
                f"pi_models_json is missing from {where()}, or this host has not "
                f"deployed since it was added."
            )
        else:
            errors.append(
                f"{path} does not exist, so no seat can be checked against a catalog. "
                f"Set modelsJsonFile in this host's pi-coding-agent config and add "
                f"pi_models_json to {where()}."
            )
        return {}
    except (OSError, ValueError) as e:
        errors.append(
            f"{path}: cannot read it as JSON ({type(e).__name__}). Fix pi_models_json in {where()}."
        )
        return {}


def where():
    return f"`sops edit {SOURCE}`" if SOURCE else "this host's sops file"


def lookup(catalog, provider, model):
    for entry in catalog.get("providers", {}).get(provider, {}).get("models", []):
        if entry.get("id") == model:
            return entry
    return None


def cmd_source():
    if SOURCE:
        print(SOURCE)
    return 0


def cmd_get(var):
    value = os.environ.get(var) or file_seats().get(var)
    if value:
        print(value)
    return 0


def cmd_list():
    for var, value in file_seats().items():
        if SEAT_SHAPE.fullmatch(var):
            print(f"{var}\t{value}")
    return 0


def cmd_check(deploy, requires):
    errors, warnings = [], []
    path = seats_path()

    known = list(FIXED)
    required = ["PI_SESSION_MODEL"]
    for name, fields in agents():
        if not AGENT_NAME.fullmatch(fields["name"]):
            errors.append(
                f"agents/{name}: name is not [A-Za-z0-9_]+, so no variable can hold its seat. Rename the agent in its frontmatter."
            )
            continue
        var = "PI_AGENT_MODEL_" + fields["name"].upper()
        known.append(var)
        if fields.get("seat") == "required":
            required.append(var)
    known = dict.fromkeys(known + requires)
    required = dict.fromkeys(required + requires)

    good, bad = read_lines()
    for n in bad:
        errors.append(
            f"{path}:{n}: not VAR=value. Each line of pi_seats is blank, a # comment, or VAR=provider/id[:level] with no spaces."
        )
    first = {}
    for n, var, _value in good:
        if var not in known:
            errors.append(
                f"{var} ({path}:{n}): not a seat, so nothing reads it. Seats here: {', '.join(known)}."
            )
        elif var in first:
            errors.append(
                f"{var}: set on lines {first[var]} and {n} of {path}. Keep one."
            )
        else:
            first[var] = n
    in_file = {var: value for _n, var, value in good if var in known}

    seats = {}
    for var in known:
        value = in_file.get(var) if deploy else os.environ.get(var) or in_file.get(var)
        if value:
            seats[var] = value

    missing = path is not None and not path.exists()
    for var in required:
        if var not in seats:
            hint = (
                f" {path} does not exist: pi_seats is missing from {where()}, or this host has not deployed since it was added."
                if missing
                else ""
            )
            errors.append(
                f"{var}: required, and not set. Add a {var}=provider/id[:level] line to pi_seats.{hint}"
            )

    catalog = load_catalog(errors, needed=bool(seats) and bool(SEATS_FILE or TRUSTED))
    parsed = {}
    for var, value in seats.items():
        seat = parse(value)
        if seat is None:
            errors.append(
                f"{var}: not provider/id[:level]. Write the provider, a /, the model id, and optionally :{'|'.join(LEVELS)}."
            )
            continue
        parsed[var] = seat
        provider, model, level = seat
        if TRUSTED and provider not in TRUSTED:
            errors.append(
                f"{var}: its provider is not one of {', '.join(TRUSTED)}, the only ones allowed to see this host's model ids. "
                f"Point it at a model on one of those, or add the provider to trustedProviders in this host's config."
            )
            continue
        entry = lookup(catalog, provider, model)
        if entry is None:
            if deploy:
                errors.append(
                    f"{var}: its id is not listed under its provider in models.json. "
                    f"Add the model to pi_models_json, or fix the id in the seat."
                )
            else:
                warnings.append(
                    f"{var}: not in the catalog, so pi runs it as a custom model with its provider's defaults."
                )
            continue
        if level is not None:
            levels = entry.get("thinkingLevelMap") or {}
            if level in levels and levels[level] is None:
                errors.append(
                    f"{var}: level {level} maps to null in the model's thinkingLevelMap, so pi would not send it. "
                    f"Use a level the map gives a value, or drop the :level suffix."
                )
            elif level != "off" and entry.get("reasoning") is False:
                errors.append(
                    f'{var}: level {level} would do nothing: the model\'s catalog entry says "reasoning": false. '
                    f"Use :off, or drop the :level suffix."
                )
        if var == "PI_AGENT_MODEL_VISION" and "image" not in (entry.get("input") or []):
            errors.append(
                f'{var}: the model\'s catalog entry has no "image" in input, so the vision agent could not send it images. '
                f"Point the seat at a model whose entry declares image input, and run mcloud-pins to confirm the endpoint accepts images."
            )

    session = parsed.get("PI_SESSION_MODEL")
    for var in ("PI_ADVISOR_MODEL", "PI_AGENT_MODEL_CRITIC"):
        if session and var in parsed and parsed[var][:2] == session[:2]:
            errors.append(
                f"{var}: same model as PI_SESSION_MODEL, so it would share the blind spots it is there to catch. "
                f"Pick another model, ideally from another family."
            )

    for warning in warnings:
        print(f"pi-seats: warning: {warning}", file=sys.stderr)
    for error in errors:
        print(f"pi-seats: {error}", file=sys.stderr)
    if errors:
        print(
            f"pi-seats: {len(errors)} problem(s). The seats and catalog are edited with {where()}, then a redeploy.",
            file=sys.stderr,
        )
        return 1
    if deploy:
        print(f"pi-seats: {len(seats)} seats ok")
    return 0


def main(argv):
    args = argv[1:]
    try:
        if len(args) == 2 and args[0] == "get" and SEAT_SHAPE.fullmatch(args[1]):
            return cmd_get(args[1])
        if args == ["list"]:
            return cmd_list()
        if args == ["source"]:
            return cmd_source()
        if args == ["check", "--deploy"]:
            return cmd_check(True, [])
        if args[:2] == ["check", "--start"]:
            flags, names = args[2::2], args[3::2]
            if len(flags) == len(names) and all(
                f == "--require" and SEAT_SHAPE.fullmatch(v)
                for f, v in zip(flags, names)
            ):
                return cmd_check(False, names)
    except Unreadable as e:
        print(f"pi-seats: {e}", file=sys.stderr)
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
