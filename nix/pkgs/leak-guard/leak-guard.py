"""Keep private model ids out of everything pushed to the public remote.

  leak-guard msg <file>      commit-msg hook: the message, plus the staged
                             diff's added lines
  leak-guard push            pre-push hook: each ref name, then the message
                             and added lines of every commit origin lacks
  leak-guard refresh         rebuild the deny-list
  leak-guard install         write both hooks into this clone's hooks dir

The deny-list is ~/.local/state/leak-guard/deny: one `provider/id`, or the
host of a provider's baseUrl, per line, in the order each was first seen. It only grows, since a model dropped from
the catalog can still be unannounced, and it stays outside every repo and the
Nix store. A hit names the entry's line number, never the entry, because the
output lands in terminals and agent transcripts.

There is no override. A false positive gets fixed in `needle`.
"""

import ipaddress
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

DENY = Path.home() / ".local/state/leak-guard/deny"
MODELS_JSON = Path.home() / ".pi/agent/models.json"
# Every model id compiled into the installed pi, extracted at build time.
BUILTINS = Path("@builtins@")
# This host's command printing the mcloud key, set at build time.
KEY_COMMAND = "@keyCommand@"
MAX_AGE_DAYS = 7
PROTECTED_BRANCHES = re.compile(r"refs/heads/(modular|work-archive)")
ZERO_SHA = re.compile(r"^0+$")

# A token is a run of these. `/` and `:` stay out, so `mcloud/<org>/<name>`
# and `<name>:high` still match a bare `<name>`. After the name, a `.` and a
# digit make a different version (`-5` vs `-5.1`); any other `.` ends a
# sentence or starts a file extension.
BEFORE = r"(?<![A-Za-z0-9._-])"
AFTER = r"(?![A-Za-z0-9_-]|\.[0-9])"

HOOKS = {
    "commit-msg": "msg",
    "pre-push": "push",
}


class Refusal(Exception):
    pass


def git(*args):
    return subprocess.run(
        ["git", *args], check=True, capture_output=True
    ).stdout.decode("utf-8", "replace")


def load_builtins():
    ids = BUILTINS.read_text().split()
    return {i.lower() for i in ids} | {i.rsplit("/", 1)[-1].lower() for i in ids}


def loose(s):
    """`s` with each run of non-alphanumerics between its parts relaxed to
    any such run or none, so `foo-9.1` also matches the display name
    `Foo 9.1` and `foo_91`."""
    return "[^A-Za-z0-9]*".join(map(re.escape, re.findall(r"[A-Za-z0-9]+", s)))


def needle(entry, builtins):
    """The pattern that counts as naming `entry`, matched against one line.

    A name pi's own catalog carries is public, so it counts only next to
    what ties it to the provider: the org in front of it, or the provider's
    own name anywhere on the same line, which covers `mcloud/<name>`,
    `mcloud/<any org>/<name>` and "mcloud serves <name>". That lets public
    model names through in docs and tiger's config while still catching
    which of them a provider serves. A line break between the two lets it
    through. An entry with no `/` is an endpoint's host and counts as
    written.
    """
    if "/" not in entry:
        return BEFORE + re.escape(entry) + AFTER
    provider, _, model = entry.partition("/")
    name = BEFORE + loose(model.rsplit("/", 1)[-1]) + AFTER
    if model.rsplit("/", 1)[-1].lower() not in builtins:
        return name
    named = r"(?<![A-Za-z0-9])" + re.escape(provider) + r"(?![A-Za-z0-9])"
    forms = [named + ".*" + name, name + ".*" + named]
    if "/" in model:
        forms.append(BEFORE + "/".join(map(loose, model.split("/"))) + AFTER)
    return "|".join(forms)


class Patterns:
    """One alternation to find a line with any hit, then each entry's own
    pattern to say which. Nearly every line has none."""

    def __init__(self, entries):
        builtins = load_builtins()
        needles = {
            n: needle(e, builtins) for n, e in enumerate(entries, 1) if e.strip()
        }
        self.each = [(n, re.compile(s, re.I)) for n, s in needles.items()]
        self.any = (
            re.compile("|".join(f"(?:{s})" for s in needles.values()), re.I)
            if needles
            else None
        )


def load_deny():
    """Patterns, or None when there is no list."""
    try:
        return Patterns(DENY.read_text().splitlines())
    except FileNotFoundError:
        return None


def scan(patterns, where, text, hits):
    if patterns.any is None or not patterns.any.search(text):
        return
    for n, pattern in patterns.each:
        if pattern.search(text):
            hits.append(f"{where}: deny-list entry {n}")


def shown(patterns, text):
    """A path or ref name for a hit's location, unless it is itself a hit."""
    if patterns.any is not None and patterns.any.search(text):
        return "(redacted)"
    return text


def scan_message(patterns, label, message, hits):
    for i, line in enumerate(message.splitlines(), 1):
        scan(patterns, f"{label} line {i}", line, hits)


def scan_diff(patterns, label, diff, hits):
    """Added lines only. Binary blobs, git-crypt's included under
    --no-textconv, show up as a `Binary files` line and are skipped."""
    path, lineno, header = "?", 0, True
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            header = True
        elif header and line.startswith("+++ "):
            path = line[4:].removeprefix("b/")
            scan(patterns, f"{label}path", path, hits)
            path = shown(patterns, path)
        elif line.startswith("@@"):
            header = False
            m = re.match(r"@@ -\S+ \+(\d+)", line)
            lineno = int(m.group(1)) if m else 0
        elif not header and line.startswith("+"):
            scan(patterns, f"{label}{path}:{lineno}", line[1:], hits)
            lineno += 1


# The prefixes override diff.noprefix and diff.mnemonicPrefix.
DIFF_FLAGS = [
    "-U0",
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--src-prefix=a/",
    "--dst-prefix=b/",
]


def models_json():
    try:
        return json.loads(MODELS_JSON.read_text())
    except FileNotFoundError:
        return {}


def mcloud_base_url(catalog):
    return catalog.get("providers", {}).get("mcloud", {}).get("baseUrl")


def endpoint_hosts(catalog):
    """The host of each provider's baseUrl, loopback aside."""
    hosts = []
    for block in catalog.get("providers", {}).values():
        host = urllib.parse.urlsplit(block.get("baseUrl") or "").hostname
        if not host or host == "localhost":
            continue
        try:
            if ipaddress.ip_address(host).is_loopback:
                continue
        except ValueError:
            pass
        hosts.append(host)
    return hosts


def mcloud_key():
    key = os.environ.get("MCLOUD_API_KEY", "")
    command = os.environ.get("MCLOUD_API_KEY_COMMAND") or KEY_COMMAND
    if not key and command:
        key = subprocess.run(
            ["sh", "-c", command], capture_output=True, text=True
        ).stdout.strip()
    if not key:
        raise Refusal(
            "no mcloud key: set keyCommand where this host installs leak-guard and deploy; "
            "MCLOUD_API_KEY or MCLOUD_API_KEY_COMMAND covers a single run"
        )
    return key


def refresh():
    """Grow the deny-list from models.json's ids and endpoint hosts and
    the live mcloud catalog.

    Writes nothing unless the live fetch succeeds, so the list's mtime says
    when it last matched what mcloud serves.
    """
    catalog = models_json()
    found = [
        f"{provider}/{model['id']}"
        for provider, block in catalog.get("providers", {}).items()
        for model in block.get("models", [])
        if model.get("id")
    ] + endpoint_hosts(catalog)
    base_url = mcloud_base_url(catalog)
    if base_url:
        request = urllib.request.Request(
            base_url.rstrip("/") + "/models",
            headers={"Authorization": f"Bearer {mcloud_key()}"},
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                served = json.load(response)["data"]
        except Exception as e:
            raise Refusal(f"fetching the mcloud catalog failed: {type(e).__name__}")
        found += [f"mcloud/{m['id']}" for m in served]

    try:
        entries = DENY.read_text().splitlines()
    except FileNotFoundError:
        entries = []
    known = {e.lower() for e in entries}
    new = sorted({f for f in found if f.lower() not in known}, key=str.lower)

    DENY.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = DENY.with_name("deny.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("".join(e + "\n" for e in entries + new))
    tmp.replace(DENY)
    return len(entries) + len(new), len(new)


def fresh_patterns():
    """Refresh where this host's pi reaches mcloud, and refuse rather than
    push against a list that is missing or a week behind the catalog."""
    if not mcloud_base_url(models_json()):
        return load_deny() or Patterns([])
    try:
        refresh()
    except Refusal as e:
        try:
            age = (time.time() - DENY.stat().st_mtime) / 86400
        except FileNotFoundError:
            raise Refusal(f"{e}, and there is no deny-list at {DENY}")
        if age > MAX_AGE_DAYS:
            raise Refusal(f"{e}, and the deny-list is {age:.0f} days old")
        print(
            f"leak-guard: {e}; checking against the {age:.1f}-day-old list",
            file=sys.stderr,
        )
    return load_deny()


def cmd_msg(path):
    patterns = load_deny()
    if patterns is None:
        print(
            f"leak-guard: no deny-list at {DENY}, so this commit went unchecked; run `leak-guard refresh`",
            file=sys.stderr,
        )
        return []
    hits = []
    message = []
    # Comment lines are checked too: `commit -m` keeps a `#` line, since git
    # strips comments only from a message it opened an editor for.
    for line in Path(path).read_text(errors="replace").splitlines():
        # `commit -v` appends the diff below a scissors line, removed lines
        # included; the staged diff below covers what that section adds.
        if re.match(r"^. -+ >8 -+$", line):
            break
        message.append(line)
    scan_message(patterns, "commit message", "\n".join(message), hits)
    scan_diff(patterns, "staged ", git("diff", "--cached", *DIFF_FLAGS), hits)
    return hits


def cmd_push():
    patterns = fresh_patterns()
    hits = []
    for line in sys.stdin:
        local_ref, local_sha, remote_ref, _remote_sha = line.split()
        if PROTECTED_BRANCHES.search(local_ref):
            raise Refusal(f"{shown(patterns, local_ref)} never leaves this machine")
        for ref in {local_ref, remote_ref}:
            scan(patterns, "ref name", ref, hits)
        local_ref = shown(patterns, local_ref)
        if ZERO_SHA.match(local_sha):
            continue
        if git("cat-file", "-t", local_sha).strip() == "tag":
            scan_message(
                patterns, f"tag {local_ref}", git("cat-file", "tag", local_sha), hits
            )
        # origin is the public remote and its tracking refs say what it
        # already holds. Each commit gets its own diff, merges once per
        # parent, so an id added and later removed in the same push still
        # counts: it would be in the history either way.
        log = git(
            "log",
            "-p",
            "-m",
            "--format=%x00%H%n%B%x00",
            *DIFF_FLAGS,
            local_sha,
            "--not",
            "--remotes=origin",
        )
        label = ""
        for chunk in log.split("\0")[1:]:
            if re.fullmatch(r"[0-9a-f]{40,64}\n.*", chunk, re.S):
                sha, _, message = chunk.partition("\n")
                label = sha[:12]
                scan_message(patterns, f"{label} message", message, hits)
            else:
                scan_diff(patterns, f"{label} ", chunk, hits)
    return hits


def cmd_install():
    hooks = Path(git("rev-parse", "--git-path", "hooks").strip())
    hooks.mkdir(parents=True, exist_ok=True)
    for hook, mode in HOOKS.items():
        body = (
            "#!/usr/bin/env bash\n"
            "# Written by `leak-guard install`. Fails closed when leak-guard is\n"
            "# not on PATH: bash exits 127 and git refuses.\n"
            "set -euo pipefail\n"
            f'exec leak-guard {mode} "$@"\n'
        )
        target = hooks / hook
        if target.exists() and target.read_text() != body:
            raise Refusal(
                f"{target} exists and is not leak-guard's; fold it in or remove it, then rerun"
            )
        target.write_text(body)
        target.chmod(0o755)
        print(f"leak-guard: wrote {target}")


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    try:
        if mode == "msg" and len(argv) == 3:
            hits = cmd_msg(argv[2])
        elif mode == "push":
            hits = cmd_push()
        elif mode == "refresh" and len(argv) == 2:
            total, new = refresh()
            print(f"leak-guard: {total} entries, {new} new")
            return 0
        elif mode == "install" and len(argv) == 2:
            cmd_install()
            return 0
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except Refusal as e:
        print(f"leak-guard: refusing: {e}", file=sys.stderr)
        return 1
    if not hits:
        return 0
    print("leak-guard: refusing, these name a private model id:", file=sys.stderr)
    for hit in dict.fromkeys(hits):
        print(f"  {hit}", file=sys.stderr)
    print(
        f"Entry N is line N of {DENY}. Rewrite the text; there is no override.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
