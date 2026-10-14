"""Resolve and check the engine's model seats.

  alamode-seats get VAR             the effective value: the caller's env when
                               non-empty, else the seats file, else nothing
  alamode-seats list                VAR<TAB>value for each seat in the seats file
  alamode-seats check --deploy      the seats file's values; an id missing from
                               the catalog fails
  alamode-seats check --start [--require VAR]...
                               the effective values; only a problem in the
                               session's seat or a required one fails, the
                               rest warn, and an id missing from the catalog
                               only warns
  alamode-seats source              the sops file this host's seats and catalog
                               are edited in, or nothing

A seat is an env var holding `provider/id[:level]`. The seats file holds
`VAR=value` lines and is parsed, never sourced. Messages name a variable or
a provider, never a value, because they land in deploy logs and agent
transcripts, and each one says what to change.
"""

import importlib.util
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
# Repo path of the sops file holding alamode_seats and alamode_models_json,
# for the fix-it lines. Empty when the host didn't name one.
SOURCE = "@secretsSource@"
# The inference relay's module and the plain-HTTP hosts it may contact, so a
# deploy check refuses the same catalog the relay would at session start.
RELAY_MODULE = "@relayModule@"
PRIVATE_HOSTS = [h for h in "@privateProviderHosts@".split(",") if h]
AGENT_DIR = Path(os.environ.get("PI_CODING_AGENT_DIR", Path.home() / ".pi/agent"))

LEVELS = ("off", "minimal", "low", "medium", "high", "xhigh", "max")
FIXED = (
    "ALAMODE_SESSION_MODEL",
    "ALAMODE_ADVISOR_MODEL",
    "ALAMODE_SPAWN_MODEL",
    "ALAMODE_DELEGATE_MODEL",
    "ALAMODE_CLASSIFY_MODEL",
)
SEAT_SHAPE = re.compile(
    r"ALAMODE_(SESSION|ADVISOR|SPAWN|DELEGATE|CLASSIFY)_MODEL|ALAMODE_AGENT_MODEL_[A-Z0-9_]+"
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

    the engine's own split: the provider ends at the first `/`, and a suffix after
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
                f"alamode_models_json is missing from {where()}, or this host has not "
                f"deployed since it was added."
            )
        else:
            errors.append(
                f"{path} does not exist, so no seat can be checked against a catalog. "
                f"Set modelsJsonFile in this host's alamode config and add "
                f"alamode_models_json to {where()}."
            )
        return {}
    except (OSError, ValueError) as e:
        errors.append(
            f"{path}: cannot read it as JSON ({type(e).__name__}). Fix alamode_models_json in {where()}."
        )
        return {}


def where():
    return f"`sops edit {SOURCE}`" if SOURCE else "this host's sops file"


def relay_refusals(catalog):
    """(provider, error) for each trusted provider the inference relay
    refuses. The relay's route planning validates endpoints, APIs and
    limits without a server, and runs here with no credential resolved."""
    if not RELAY_MODULE:
        return
    spec = importlib.util.spec_from_file_location("relay", RELAY_MODULE)
    relay = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(relay)
    for name, data in catalog.get("providers", {}).items():
        if TRUSTED and name not in TRUSTED:
            continue
        try:
            relay.provider_routes(
                {"providers": {name: data}}, {}, allow_private_hosts=PRIVATE_HOSTS
            )
        except (ValueError, KeyError, TypeError) as e:
            yield name, e


def lookup(catalog, provider, model):
    for entry in catalog.get("providers", {}).get(provider, {}).get("models", []):
        if entry.get("id") == model:
            return entry
    return None


def runs_at(entry, level):
    """The level pi 1.0.0 runs a seat at, and why when that differs.

    pi-ai's getSupportedThinkingLevels and clampThinkingLevel: an entry
    without "reasoning": true supports only off; a level mapped to null, and
    xhigh or max without a mapping, is unsupported. An unsupported level
    moves to the nearest supported one, searching up first.
    """
    levels = entry.get("thinkingLevelMap") or {}
    if entry.get("reasoning") is not True:
        supported = ["off"]
        why = 'its catalog entry does not say "reasoning": true'
    else:
        supported = [
            lv
            for lv in LEVELS
            if not (lv in levels and levels[lv] is None)
            and (lv not in ("xhigh", "max") or lv in levels)
        ]
        if level in levels:
            why = f"the entry's thinkingLevelMap maps {level} to null"
        else:
            why = f"the engine runs {level} only when the entry's thinkingLevelMap names it"
    if level in supported:
        return level, None
    i = LEVELS.index(level)
    for lv in LEVELS[i:] + LEVELS[:i][::-1]:
        if lv in supported:
            return lv, why
    return "off", why


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
    session_seats = {"ALAMODE_SESSION_MODEL", *requires}

    def problem(var, message):
        """At deploy every problem fails. At start only one in a seat this
        session runs on does, so a missing vision seat doesn't stop the
        session: every other seat's consumer refuses on its own when used
        (task.ts, or the wrapper a child or the classifier starts through)."""
        (errors if deploy or var in session_seats else warnings).append(message)

    known = list(FIXED)
    required = ["ALAMODE_SESSION_MODEL"]
    needs_image = set()
    for name, fields in agents():
        if not AGENT_NAME.fullmatch(fields["name"]):
            problem(
                None,
                f"agents/{name}: name is not [A-Za-z0-9_]+, so no variable can hold its seat. Rename the agent in its frontmatter.",
            )
            continue
        var = "ALAMODE_AGENT_MODEL_" + fields["name"].upper()
        known.append(var)
        if fields.get("seat") == "required":
            required.append(var)
        if fields.get("needs") == "image":
            needs_image.add(var)
    known = dict.fromkeys(known + requires)
    required = dict.fromkeys(required + requires)

    good, bad = read_lines()
    for n in bad:
        problem(
            None,
            f"{path}:{n}: not VAR=value. Each line of alamode_seats is blank, a # comment, or VAR=provider/id[:level] with no spaces.",
        )
    first = {}
    for n, var, _value in good:
        if var not in known:
            problem(
                None,
                f"{var} ({path}:{n}): not a seat, so nothing reads it. Seats here: {', '.join(known)}.",
            )
        elif var in first:
            problem(
                var, f"{var}: set on lines {first[var]} and {n} of {path}. Keep one."
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
                f" {path} does not exist: alamode_seats is missing from {where()}, or this host has not deployed since it was added."
                if missing
                else ""
            )
            problem(
                var,
                f"{var}: required, and not set. Add a {var}=provider/id[:level] line to alamode_seats.{hint}",
            )

    catalog = load_catalog(errors, needed=bool(seats) and bool(SEATS_FILE or TRUSTED))
    parsed = {}
    for var, value in seats.items():
        seat = parse(value)
        if seat is None:
            problem(
                var,
                f"{var}: not provider/id[:level]. Write the provider, a /, the model id, and optionally :{'|'.join(LEVELS)}.",
            )
            continue
        parsed[var] = seat
        provider, model, level = seat
        if TRUSTED and provider not in TRUSTED:
            problem(
                var,
                f"{var}: its provider is not one of {', '.join(TRUSTED)}, the only ones allowed to see this host's model ids. "
                f"Point it at a model on one of those, or add the provider to trustedProviders in this host's config.",
            )
            continue
        entry = lookup(catalog, provider, model)
        if entry is None:
            if deploy:
                problem(
                    var,
                    f"{var}: its id is not listed under its provider in models.json. "
                    f"Add the model to alamode_models_json, or fix the id in the seat.",
                )
            else:
                warnings.append(
                    f"{var}: not in the catalog, so the engine runs it as a custom model with its provider's defaults."
                )
            continue
        if level is not None:
            runs, why = runs_at(entry, level)
            if why and entry.get("reasoning") is not True:
                problem(
                    var,
                    f"{var}: the engine runs level {level} as {runs}: {why}. "
                    f'Add "reasoning": true to the entry in alamode_models_json if the model reasons, or use :{runs}, in {where()}.',
                )
            elif why:
                problem(
                    var,
                    f"{var}: the engine runs level {level} as {runs}: {why}. "
                    f'Give the entry\'s thinkingLevelMap a "{level}" value the endpoint takes in alamode_models_json, or use :{runs}, in {where()}.',
                )
        if var in needs_image and "image" not in (entry.get("input") or []):
            problem(
                var,
                f'{var}: the model\'s catalog entry has no "image" in input, and its agent says `needs: image`, so every image would be dropped. '
                f"Point the seat at a model whose entry declares image input and passes mcloud-pins' image check.",
            )

    if deploy:
        for name, e in relay_refusals(catalog):
            problem(
                None,
                f"{name}: the inference relay refuses this provider ({e}), so every session fails before pi starts. "
                f"Fix its entry in alamode_models_json with {where()}, or name its plain-HTTP host in sandbox.privateProviderHosts in this host's config.",
            )

    session = parsed.get("ALAMODE_SESSION_MODEL")
    for var in ("ALAMODE_ADVISOR_MODEL", "ALAMODE_AGENT_MODEL_CRITIC"):
        if session and var in parsed and parsed[var][:2] == session[:2]:
            problem(
                var,
                f"{var}: same model as ALAMODE_SESSION_MODEL, so it would share the blind spots it is there to catch. "
                f"Pick another model, ideally from another family.",
            )

    for warning in warnings:
        print(f"alamode-seats: warning: {warning}", file=sys.stderr)
    for error in errors:
        print(f"alamode-seats: {error}", file=sys.stderr)
    if errors:
        print(
            f"alamode-seats: {len(errors)} problem(s). The seats and catalog are edited with {where()}, then a redeploy.",
            file=sys.stderr,
        )
        return 1
    if warnings and not deploy:
        print(
            f"alamode-seats: {len(warnings)} warning(s), which fail the next deploy check; a seat warned about refuses when it is used. "
            f"Edit with {where()}, then redeploy.",
            file=sys.stderr,
        )
    if deploy:
        print(f"alamode-seats: {len(seats)} seats ok")
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
        print(f"alamode-seats: {e}", file=sys.stderr)
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
