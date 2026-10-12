"""Trusted session admission. Workload configuration never grants host authority."""

import argparse
from contextlib import ExitStack
import fcntl
import hashlib
import importlib.util
import ipaddress
import json
import os
import pwd
from pathlib import Path
import re
import secrets
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).parent))
from common import request, socket_directory
import workspace

ID = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}\Z")
PRIVATE_NETWORKS = [
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "224.0.0.0/4",
    "::/128",
    "::1/128",
    "fc00::/7",
    "fe80::/10",
    "ff00::/8",
]
SAFE_ENV = (
    "TERM",
    "COLORTERM",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TZ",
    "TERM_PROGRAM",
    "SSL_CERT_FILE",
    "NIX_SSL_CERT_FILE",
)


class SessionError(RuntimeError):
    pass


def read_json(path):
    with open(path) as stream:
        return json.load(stream)


def write_json(path, data):
    path = Path(path)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        json.dump(data, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
        temporary = stream.name
    os.replace(temporary, path)


def directory(path):
    path = Path(path)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_mode & 0o077
    ):
        raise SessionError(f"Expected a private directory owned by you: {path}")
    return path.resolve()


def expand(value, home):
    if value == "~" or value.startswith("~/"):
        value = str(home) + value[1:]
    if not os.path.isabs(value):
        raise SessionError(f"Grant must name an absolute path: {value}")
    return str(Path(value).resolve())


def pin_store_roots(config, directories=None, control=None, store_tool=None):
    """Pin the deployment's store packages as Nix garbage-collector roots.

    A `nix store gc` between deploys, `make cleanup` mid-session included,
    deletes a live session's interpreter out of the store, and every exec
    of $ALAMODE_REAL_BIN fails until the identical path is rebuilt, because
    pi, the runtime and the sandbox libraries reach the wrapper through
    string-interpolated paths rather than closure edges the home-manager
    profile already pins. Where a scanned gcroots directory is
    writable the pin is a plain symlink; where it is not (this host's
    /nix/var/nix/gcroots/per-user is root-owned), `nix-store --add-root`
    registers the same symlink as an indirect root and the daemon writes
    gcroots/auto itself, so the pin lands under the private control directory
    instead. Roots are named for the store path they pin, so a redeploy
    retargets the same name and roots from older deployments are left in
    place: deleting one is exactly the race this exists to close, and they
    are visible in `nix store gc --list-roots` for the human to prune between
    sessions. Best effort throughout, because a gcroots directory that can
    take no pin must leave today's behavior unchanged.
    """
    roots = set()
    for value in config.values():
        if not isinstance(value, str) or os.pathsep in value:
            continue  # The PATH list is colon-joined and never a store path.
        parts = Path(value).parts
        if len(parts) >= 4 and parts[:3] == ("/", "nix", "store"):
            roots.add(str(Path(*parts[:4])))
    user = pwd.getpwuid(os.getuid()).pw_name
    pinned = set()
    for directory in (
        directories
        if directories is not None
        else [
            Path("/nix/var/nix/gcroots/per-user") / user,
            Path("/nix/var/nix/gcroots"),
        ]
    ):
        try:
            directory.mkdir(mode=0o755, parents=True, exist_ok=True)
        except OSError:
            continue
        if not os.access(directory, os.W_OK):
            continue
        for root in sorted(roots):
            link = directory / ("alamode-" + Path(root).name)
            try:
                if link.is_symlink() and os.readlink(link) == root:
                    pinned.add(root)
                    continue
                temporary = directory / ("alamode-tmp-" + secrets.token_hex(6))
                os.symlink(root, temporary)
                os.replace(temporary, link)
                pinned.add(root)
            except OSError:
                continue
    if control is None or pinned == roots:
        return
    tool = store_tool or shutil.which("nix-store") or "nix-store"
    links = control / "gcroots"
    try:
        links.mkdir(mode=0o700, parents=True, exist_ok=True)
    except OSError:
        return
    for root in sorted(roots - pinned):
        link = links / ("alamode-" + Path(root).name)
        try:
            if link.is_symlink() and os.readlink(link) == root:
                continue
            if link.is_symlink():
                link.unlink()
            subprocess.run(
                [tool, "--add-root", str(link), "--realise", root],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError:
            continue


VERBS = {"resume", "sessions", "coord", "delegate", "seats"}

HELP = """alamode [--profile NAME] [--web] [--allow HOST] [--listen PORT]
        [--allow-read PATH] [--allow-write PATH] [--allow-rw PATH]
        [--allow-nix] [--allow-git-write] [--no-git-write]
        [--allow-trustd] [--allow-forge] [--allow-clipboard]
        [--allow-BUNDLE] [--local] [-- PI ARGS]
alamode resume [ID] [-- PI ARGS]
alamode sessions [show ID | export ID]
alamode coord [GRANTS] | attach ID | start [GRANTS] | ls | stop ID
alamode delegate ... | seats ...

A launch snapshots the current repository into private Git storage.
Outside a repository, launches use an empty private scratch workspace.
Grants persist on resume. Provider credentials stay in the host relay.
Flags after -- reach pi verbatim; alamode flags never follow it.
--allow-nix requires a configured isolated builder.
--local admits only loopback models and refuses every network grant.
coord start prints JSON credentials without opening the UI."""


def split_boundary(argv):
    # The -- boundary is hard: alamode flags come before it, engine
    # arguments after. Nothing before -- may be an engine flag, so the
    # engine can never grow a flag that silently changes alamode's meaning.
    if "--" in argv:
        index = argv.index("--")
        return list(argv[:index]), list(argv[index + 1 :])
    return list(argv), []


class Parser(argparse.ArgumentParser):
    # Strict parsing: an unknown flag or positional before -- is a mistake
    # about which program owns it, never a silent passthrough.
    def error(self, message):
        raise SessionError(
            f"{message}; alamode flags come first, engine arguments go after --"
        )


def apply_profiles(options, config):
    profiles = config.get("profiles", {})
    for name in options.profile:
        if name not in profiles:
            raise SessionError(f"Unknown profile: {name}")
        preset = profiles[name]
        options.allow.extend(preset.get("domains", []))
        options.allow_read.extend(preset.get("readPaths", []))
        options.allow_write.extend(preset.get("writePaths", []))
        options.listen.extend(preset.get("listenPorts", []))
        if preset.get("trustd"):
            options.allow_trustd = True
        if preset.get("nix"):
            options.allow_nix = True
        if preset.get("forge"):
            options.allow_forge = True
        for bundle in preset.get("bundles", []):
            setattr(options, "bundle_" + bundle, True)


def parse(args, config):
    parser = Parser(add_help=False, allow_abbrev=False)
    parser.add_argument("--managed-manifest")
    parser.add_argument("--web", action="store_true")
    parser.add_argument("--allow", action="append", default=[])
    for option in ("read", "write", "rw"):
        parser.add_argument("--allow-" + option, action="append", default=[])
    parser.add_argument("--listen", type=int, action="append", default=[])
    parser.add_argument("--allow-git-write", action="store_true")
    parser.add_argument("--no-git-write", action="store_true")
    parser.add_argument("--allow-trustd", action="store_true")
    parser.add_argument("--allow-nix", action="store_true")
    parser.add_argument("--allow-forge", action="store_true")
    parser.add_argument("--allow-clipboard", action="store_true")
    parser.add_argument("--local", action="store_true")
    parser.add_argument("--profile", action="append", default=[])
    for name in config["bundles"]:
        parser.add_argument(
            "--allow-" + name, action="store_true", dest="bundle_" + name
        )
    for arg in args:
        if arg in ("--no-sandbox", "--resume", "--continue", "-r", "-c"):
            raise SessionError(
                f"alamode does not support {arg}; sessions are managed with alamode resume"
            )
    options = parser.parse_args(args)
    apply_profiles(options, config)
    return options


def requested_grants(options, config):
    return bool(
        options.web
        or options.allow
        or options.allow_read
        or options.allow_write
        or options.allow_rw
        or options.listen
        or options.allow_nix
        or options.allow_forge
        or options.allow_trustd
        or options.allow_clipboard
        or options.local
        or options.no_git_write
        or options.allow_git_write
        or options.profile
        or any(getattr(options, "bundle_" + name) for name in config["bundles"])
    )


def refuse_grant_changes(options, config):
    if requested_grants(options, config):
        raise SessionError(
            "Resume uses the recorded grants; start a new session to change authority"
        )


def require_recorded_runtime(manifest, configuration_path):
    # Resume re-admits the session through this build: grants, admission and
    # the sandbox all come from the running wrapper, so a session recorded
    # by another runtime must not be re-admitted by this one. Export is
    # data-only (see export_session) and never consults the recorded
    # configuration, which is why the message names the way out rather
    # than the dead end.
    if manifest["configuration"] != configuration_path:
        raise SessionError(
            "Session was created by a different runtime; resume needs its recorded "
            f"build ({manifest['configuration']}). Export the commits with "
            f"`alamode sessions export {manifest['id']}` and start a new session."
        )


def policy(options, config, home):
    # --local drops the host's network defaults, which nobody asked for at
    # this launch, and refuses a flag that asks for the network alongside
    # it. Clipboard counts: Universal Clipboard copies it to other devices.
    if options.local:
        refused = [
            flag
            for flag, held in (
                ("--web", options.web),
                ("--allow", options.allow),
                ("--allow-nix", options.allow_nix),
                ("--allow-forge", options.allow_forge),
                ("--allow-trustd", options.allow_trustd),
                ("--allow-clipboard", options.allow_clipboard),
                *(
                    ("--allow-" + name, getattr(options, "bundle_" + name))
                    for name, bundle in config["bundles"].items()
                    if bundle.get("domains")
                    or bundle.get("nix")
                    or bundle.get("trustd")
                ),
            )
            if held
        ]
        if refused:
            raise SessionError(
                "--local refuses grants that reach off this Mac, set directly or by a profile: "
                + ", ".join(refused)
            )
    defaults = not options.local
    result = {
        "local": options.local,
        "web": options.web,
        "domains": (list(config["domains"]) if defaults else []) + options.allow,
        "read": list(config["readPaths"]) + options.allow_read + options.allow_rw,
        "write": list(config["writePaths"]) + options.allow_write + options.allow_rw,
        "listen": list(config.get("listenPorts", [])) + options.listen,
        "trustd": options.allow_trustd or (defaults and config["allowTrustd"]),
        "clipboard": options.allow_clipboard,
        "git_write": not options.no_git_write
        and (options.allow_git_write or config.get("gitWrite", True)),
        "nix": options.allow_nix or (defaults and config["allowNix"]),
        "grants": [],
        "forge": options.allow_forge,
        "forge_sizes": ["small", "large", "xlarge"] if options.allow_forge else [],
    }
    for name, bundle in config["bundles"].items():
        if not getattr(options, "bundle_" + name):
            continue
        result["grants"].append(name)
        result["domains"].extend(bundle.get("domains", []))
        result["read"].extend(bundle.get("readPaths", []))
        result["write"].extend(bundle.get("writePaths", []))
        result["trustd"] |= bundle.get("trustd", False)
        result["nix"] |= bundle.get("nix", False)
    for kind in ("read", "write"):
        result[kind] = list(
            dict.fromkeys(expand(value, home) for value in result[kind])
        )
    for port in result["listen"]:
        if not 1 <= port <= 65535:
            raise SessionError("--listen requires a port between 1 and 65535")
        result["domains"].append(f"127.0.0.1:{port}")
    if result["nix"] and not config.get("builder"):
        raise SessionError(
            "No isolated Nix builder is configured. Host daemon access is not a session grant."
        )
    return result


def loopback(url):
    host = urlsplit(url or "").hostname or ""
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def catalog_scope(catalog, config, local=False):
    models = []
    providers = config["trustedProviders"]
    for provider, data in catalog.get("providers", {}).items():
        if providers and provider not in providers:
            continue
        for model in data.get("models", []):
            effective = {
                **data,
                **model,
                **data.get("modelOverrides", {}).get(model["id"], {}),
            }
            # The relay routes to this same effective baseUrl, so a cloud
            # model never gets a route in a local session.
            if local and not loopback(effective.get("baseUrl")):
                continue
            models.append(
                {
                    "model": provider + "/" + model["id"],
                    "api": effective.get("api"),
                    "baseUrl": effective.get("baseUrl"),
                }
            )
    wire = json.dumps(models, sort_keys=True, separators=(",", ":")).encode()
    return [model["model"] for model in models], hashlib.sha256(wire).hexdigest()


def local_providers(grant):
    return list(dict.fromkeys(model.split("/")[0] for model in grant["allowed_models"]))


def local_seats(values, grant):
    # A seat is provider/id[:level]. Matched by model, not provider: one
    # provider can override a single model's baseUrl to loopback.
    allowed = set(grant["allowed_models"])
    kept = {
        key: value
        for key, value in values.items()
        if value in allowed or value.rpartition(":")[0] in allowed
    }
    return kept, sorted(values.keys() - kept.keys())


def seats(config, home):
    values = {}
    path = config.get("seatsFile")
    if path:
        for line in Path(expand(path, home)).read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, separator, value = line.partition("=")
            if not separator or not re.fullmatch(
                r"ALAMODE_[A-Z0-9_]*MODEL[A-Z0-9_]*", key
            ):
                raise SessionError("Invalid model seat assignment")
            parsed = shlex.split(value, comments=True)
            if len(parsed) != 1:
                raise SessionError("A model seat must have one value")
            values[key] = parsed[0]
    values.update(
        {
            key: value
            for key, value in os.environ.items()
            if re.fullmatch(r"ALAMODE_[A-Z0-9_]*MODEL[A-Z0-9_]*", key)
        }
    )
    return values


def resolver(value, environment, config):
    if not isinstance(value, str):
        raise SessionError("Credential reference must be a string")
    if value.startswith("!"):
        result = subprocess.run(
            [config["shell"], "-c", value[1:]],
            env=environment,
            cwd="/",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
        )
        if result.returncode:
            raise SessionError("Trusted credential resolver failed")
        return result.stdout.decode().strip()

    def replace(match):
        token = match.group(0)
        if token in ("$$", "$!"):
            return token[1:]
        name = token[2:-1] if token.startswith("${") else token[1:]
        if not environment.get(name):
            raise SessionError(f"Credential environment variable {name} is missing")
        return environment[name]

    return re.sub(
        r"\$(?:[$!]|\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)", replace, value
    )


def credentials(config, manifest, home, *, include_tools=False):
    catalog_path = config.get("catalogFile")
    if not catalog_path:
        raise SessionError(
            "Configure modelsJson or modelsJsonFile with explicit model definitions before starting alamode"
        )
    catalog = read_json(expand(catalog_path, home))
    _, digest = catalog_scope(catalog, config, manifest["policy"].get("local", False))
    if manifest["policy"].get("catalog_scope") not in (None, digest):
        raise SessionError(
            "Provider endpoints or model scope changed. Start a new session to authorize the new catalog."
        )
    allowed_providers = config.get("trustedProviders", [])
    catalog["providers"] = {
        name: data
        for name, data in catalog.get("providers", {}).items()
        if not allowed_providers or name in allowed_providers
    }
    environment = {
        key: value
        for key, value in os.environ.items()
        if key not in ("BASH_ENV", "ENV", "NODE_OPTIONS", "PYTHONPATH", "PYTHONHOME")
    }
    environment["PATH"] = config["path"]
    for key, command in config["resolvers"].items():
        gate = config["resolverGates"].get(key)
        if gate and gate not in config["bundles"]:
            raise SessionError("Credential resolver names an unknown grant")
        if gate and gate not in manifest["policy"]["grants"]:
            environment.pop(key, None)
            continue
        environment[key] = resolver("!" + command, environment, config)
    auth = {}
    for provider, data in catalog["providers"].items():
        auth[provider] = {
            "apiKey": resolver(data.get("apiKey", ""), environment, config),
            "headers": {
                key: resolver(value, environment, config)
                for key, value in data.get("headers", {}).items()
            },
            "modelHeaders": {
                model["id"]: {
                    key: resolver(value, environment, config)
                    for key, value in {
                        **data.get("modelOverrides", {})
                        .get(model["id"], {})
                        .get("headers", {}),
                        **model.get("headers", {}),
                    }.items()
                }
                for model in data.get("models", [])
            },
        }
    tool_credentials = {}
    if "kagi" in manifest["policy"]["grants"]:
        if not environment.get("KAGI_API_KEY"):
            raise SessionError(
                "The kagi grant requires a configured KAGI_API_KEY resolver"
            )
        tool_credentials["kagi"] = environment["KAGI_API_KEY"]
    return (catalog, auth, tool_credentials) if include_tools else (catalog, auth)


def safe_write(root, relative, data):
    # Runtime paths are writable by previous sessions. Never follow their
    # symlinks while preparing a resumed session outside containment.
    parent = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    parts = Path(relative).parts
    if (
        Path(relative).is_absolute()
        or not parts
        or any(part in (".", "..") for part in parts)
    ):
        os.close(parent)
        raise SessionError("Runtime writes require a relative path inside the session")
    try:
        for part in parts[:-1]:
            try:
                os.mkdir(part, mode=0o700, dir_fd=parent)
            except FileExistsError:
                pass
            child = os.open(
                part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent
            )
            os.close(parent)
            parent = child
        name = ".pi-prepare-" + secrets.token_hex(12)
        descriptor = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=parent,
        )
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        os.rename(name, parts[-1], src_dir_fd=parent, dst_dir_fd=parent)
    finally:
        os.close(parent)


def safe_read(root, relative, limit=65536):
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    parts = Path(relative).parts
    if (
        Path(relative).is_absolute()
        or not parts
        or any(part in (".", "..") for part in parts)
    ):
        os.close(descriptor)
        raise SessionError("Runtime reads require a relative path inside the session")
    try:
        for part in parts[:-1]:
            child = os.open(
                part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor
            )
            os.close(descriptor)
            descriptor = child
        child = os.open(
            parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptor
        )
        with os.fdopen(child, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise SessionError("Expected a regular session data file")
            data = stream.read(limit + 1)
            if len(data) > limit:
                raise SessionError("Session data file exceeds its size limit")
            return data
    finally:
        os.close(descriptor)


def _clear_entry(parent, name, depth):
    try:
        info = os.lstat(name, dir_fd=parent)
    except FileNotFoundError:
        return
    if not stat.S_ISDIR(info.st_mode):
        os.unlink(name, dir_fd=parent)
        return
    if depth >= 32:
        raise SessionError("Planted runtime directory is deeper than 32 levels")
    descriptor = os.open(
        name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent
    )
    try:
        with os.scandir(descriptor) as entries:
            children = [
                (entry.name, entry.is_dir(follow_symlinks=False)) for entry in entries
            ]
        for child_name, is_directory in children:
            if is_directory:
                _clear_entry(descriptor, child_name, depth + 1)
            else:
                os.unlink(child_name, dir_fd=descriptor)
    finally:
        os.close(descriptor)
    os.rmdir(name, dir_fd=parent)


def safe_clear(root, relative):
    # Runtime paths are writable by previous sessions. Never follow their
    # symlinks while removing planted state outside containment.
    parent = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    parts = Path(relative).parts
    if (
        Path(relative).is_absolute()
        or not parts
        or any(part in (".", "..") for part in parts)
    ):
        os.close(parent)
        raise SessionError("Runtime clears require a relative path inside the session")
    try:
        for part in parts[:-1]:
            try:
                child = os.open(
                    part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent
                )
            except FileNotFoundError:
                return
            os.close(parent)
            parent = child
        _clear_entry(parent, parts[-1], 0)
    finally:
        os.close(parent)


# State under the per-session agent directory that a previous run of this
# same session could have planted for its own resume: pi loads mcp.json,
# mcp-auth.json, trust.json and models-store.json with no trust decision, and
# its in-process guards load secret-guard.json and verify.json, merging the
# agent directory's copy first on every operation (docs/pi-sandbox-audit.md,
# findings 1-6). SYSTEM.md, APPEND_SYSTEM.md and the AGENTS.md/CLAUDE.md
# alternates replace or extend the system prompt and user instructions the
# same way, prompts/ adds slash commands a human can run from a resumed TUI,
# and keybindings.json rebinds its keys, so they are reclaimed too (pi 1.0.0
# docs/configuration.md names every file the agent directory contributes, and
# docs/security.md which of them load without a trust decision). bin and npm
# shadow the tools pi and its extensions run (getToolPath checks bin before
# PATH). extensions, agents, themes, grants, skills, AGENTS.md and
# keybindings.json are recopied from the store below, so clearing them first
# also drops planted extras a plain recopy would leave beside the deployed
# files. Everything pi may legitimately write for itself survives:
# settings.json, models.json and auth.json are rewritten, and
# secret-guard-violations.log, sessions, task-logs and job-logs are pi's own
# records.
PLANTED_AGENT_NAMES = (
    "mcp.json",
    "mcp-auth.json",
    "trust.json",
    "models-store.json",
    "secret-guard.json",
    "verify.json",
    "extensions",
    "agents",
    "themes",
    "grants",
    "skills",
    "bin",
    "npm",
    "SYSTEM.md",
    "APPEND_SYSTEM.md",
    "AGENTS.md",
    "AGENTS.override.md",
    "AGENTS.MD",
    "CLAUDE.md",
    "CLAUDE.MD",
    "prompts",
    "keybindings.json",
)


def child_environment(config, manifest, home, runtime):
    grants = list(manifest["policy"]["grants"])
    for key, name in (
        ("web", "web"),
        ("nix", "nix"),
        ("forge", "forge"),
        ("clipboard", "clipboard"),
        ("trustd", "trustd"),
        ("git_write", "git-write"),
    ):
        if manifest["policy"][key]:
            grants.append(name)
    if manifest.get("coordinator"):
        grants.append("coordinator")
    env = {key: os.environ[key] for key in SAFE_ENV if key in os.environ}
    env.update(
        {
            "PATH": config["path"],
            "HOME": str(runtime / "home"),
            "TMPDIR": str(runtime / "tmp"),
            "XDG_CONFIG_HOME": str(runtime / "home/.config"),
            "XDG_CACHE_HOME": str(runtime / "cache"),
            "XDG_STATE_HOME": str(runtime / "state"),
            "PI_CODING_AGENT_DIR": str(runtime / "agent"),
            "ALAMODE_SESSION_ID": manifest["id"],
            "ALAMODE_REAL_BIN": config["pi"],
            "PI_SKIP_VERSION_CHECK": "1",
            "PI_TELEMETRY": "0",
            "ALAMODE_GRANTS": ",".join(grants),
            # policy() refuses nix on a host without a builder, so a session
            # there must not be told to ask for it.
            "ALAMODE_AVAILABLE_GRANTS": ",".join(
                [
                    *(
                        name
                        for name, bundle in config["bundles"].items()
                        if config.get("builder") or not bundle.get("nix")
                    ),
                    "web",
                    *(["nix"] if config.get("builder") else []),
                    "forge",
                    "clipboard",
                    "trustd",
                    "git-write",
                ]
            ),
            "ALAMODE_TRUSTED_PROVIDERS": ",".join(
                local_providers(manifest["policy"])
                if manifest["policy"].get("local")
                else config["trustedProviders"]
            ),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": config["gitName"],
            "GIT_COMMITTER_NAME": config["gitName"],
            "GIT_AUTHOR_EMAIL": config["gitEmail"],
            "GIT_COMMITTER_EMAIL": config["gitEmail"],
            "npm_config_ignore_scripts": "true",
            "YARN_ENABLE_SCRIPTS": "false",
            "CARGO_HOME": str(runtime / "cache/cargo"),
            "RUSTUP_HOME": str(runtime / "cache/rustup"),
            "GOCACHE": str(runtime / "cache/go-build"),
            "GOMODCACHE": str(runtime / "cache/go-mod"),
            "npm_config_cache": str(runtime / "cache/npm"),
            "PIP_CACHE_DIR": str(runtime / "cache/pip"),
        }
    )
    git_config = {
        "core.hooksPath": "/dev/null",
        "core.fsmonitor": "false",
        "commit.gpgsign": "false",
        "tag.gpgsign": "false",
    }
    env["GIT_CONFIG_COUNT"] = str(len(git_config))
    for index, (key, value) in enumerate(git_config.items()):
        env[f"GIT_CONFIG_KEY_{index}"] = key
        env[f"GIT_CONFIG_VALUE_{index}"] = value
    env.update(manifest.get("seats", {}))
    for key, value in config["env"].items():
        env[key] = value.replace("$HOME", env["HOME"]).replace(
            "$PWD", manifest["workspace"]["workspace"]
        )
    coordinator = manifest.get("coordinator")
    if coordinator:
        env.update(
            ALAMODE_COORD_SOCKET=coordinator["socket"],
            ALAMODE_COORD_TOKEN=coordinator["token"],
            ALAMODE_COORD_ID=coordinator["id"],
            ALAMODE_COORD_ROLE=coordinator["role"],
        )
        if coordinator.get("agent"):
            env["ALAMODE_COORD_AGENT"] = coordinator["agent"]
        if manifest["policy"].get("forge"):
            env["ALAMODE_COORD_FORGE"] = "1"
    resources = manifest.get("resources", {}).get("forge")
    if resources:
        env.update(resources["env"])
    return env


def cased_deny(root, path):
    # A deny entry whose every component below the writable root is a glob
    # character class. APFS resolves names case-insensitively while Seatbelt
    # regexes are case-sensitive, so a variant-cased plant (`.PI/…`, `BIN/`)
    # can slip a literal deny; the class matches both spellings, and if the
    # deny never matches nothing changes. Components at or above the writable
    # root are left literal: the session cannot alias a directory it cannot
    # write, and paths outside the write roots are denied outright anyway.
    try:
        relative = Path(path).relative_to(root)
    except ValueError:
        return str(path)

    def cased(name):
        return "".join(
            f"[{character.lower()}{character.upper()}]"
            if character.isalpha()
            else character
            for character in name
        )

    return str(Path(root).joinpath(*(cased(part) for part in relative.parts)))


def sandbox_policy(config, manifest, runtime, relay_port):
    grant = manifest["policy"]
    root = manifest["workspace"]["session_root"]
    write = [root, *grant["write"]]
    read = [*config["systemReadPaths"], root, *grant["read"], *grant["write"]]
    sockets = []
    if manifest.get("coordinator"):
        sockets.append(manifest["coordinator"]["socket"])
        read += sockets
    if manifest.get("build_socket"):
        sockets.append(manifest["build_socket"])
        read.append(manifest["build_socket"])
    resources = manifest.get("resources", {}).get("forge")
    if resources:
        sockets.append(resources["socket"])
        read += [resources["socket"], *resources["read_paths"]]
    denied = [manifest["workspace"]["record_root"], "/nix/var/nix/daemon-socket"]
    for key in ("record_root", "tart_home"):
        if manifest.get("builder", {}).get(key):
            denied.append(manifest["builder"][key])
    # task.ts records every subagent fan-out under the agent directory's
    # task-logs and documents that directory as one the session can write but
    # never read back; the read deny makes that true of the session's own
    # later probes too. srt's deny filters cover the subtree beneath the
    # entry, and APFS resolves names case-insensitively while its regexes do
    # not, so the entry is case-classed like the write denies below.
    # job-logs stays readable: stall-guard points the model at `tail <job
    # log>` for live job output.
    denied.append(cased_deny(root, runtime / "agent" / "task-logs"))
    write_denied = [str(path) for path in transport_directories(manifest)]
    # In-process guards load <workspace>/.pi/secret-guard.json and verify.json
    # with no trust decision, and a planted file reaches the human's
    # unsandboxed pi through an exported bundle, so a session must not author
    # them (admit_bundle refuses the same names host-side, case-insensitively,
    # because APFS is). srt emits deny rules after the allow rules and Seatbelt
    # resolves last-match-wins, so these carve inside the write grants.
    workspace = Path(manifest["workspace"]["workspace"])
    write_denied += [
        cased_deny(root, workspace / ".pi" / name)
        for name in ("secret-guard.json", "verify.json")
    ]
    # The same guards merge agentDir()/secret-guard.json and verify.json
    # ahead of the workspace copies, re-reading them on every operation, so
    # a live write to the agent directory's copy switches a guard off in the
    # same session; the bash scanner that also refuses these names is
    # bypassable by design (runtime-assembled filenames, non-bash writers),
    # so the OS deny is the boundary.
    write_denied += [
        cased_deny(root, runtime / "agent" / name)
        for name in ("secret-guard.json", "verify.json")
    ]
    # pi prepends the agent bin dir to every child PATH and checks it before
    # PATH (getToolPath), so a session-writable binary shadows the wrapper's
    # own tools; npm is where installed extensions load from. The wrapper
    # ships fd and rg instead, and a download pi attempts anyway fails as a
    # caught warning, never a crash (ensureTool), so find falls back to PATH.
    write_denied += [
        cased_deny(root, runtime / "agent" / name) for name in ("bin", "npm")
    ]
    if not grant["git_write"]:
        write_denied.append(cased_deny(root, manifest["workspace"]["common_dir"]))
    return {
        "network": {
            "allowedDomains": list(
                dict.fromkeys(
                    [
                        *grant["domains"],
                        *([f"127.0.0.1:{relay_port}"] if relay_port else []),
                    ]
                )
            ),
            "deniedDomains": [],
            "deniedResolvedAddresses": PRIVATE_NETWORKS,
            "strictAllowlist": not grant["web"],
            "allowLocalBinding": False,
            "allowUnixSockets": sockets,
            "allowAllUnixSockets": sys.platform != "darwin",
            "allowMachLookup": ["com.apple.pasteboard.1"] if grant["clipboard"] else [],
        },
        "filesystem": {
            "denyRead": ["/", *denied],
            "allowRead": read,
            "allowWrite": write,
            "denyWrite": write_denied,
        },
        "enableWeakerNetworkIsolation": grant["trustd"],
        "allowPty": True,
    }


def transport_directories(manifest):
    paths = {
        socket_directory(),
        Path("/tmp").resolve() / f"alamode-network-{os.getuid()}",
    }
    for path in (
        manifest.get("coordinator", {}).get("socket"),
        manifest.get("build_socket"),
    ):
        if path:
            paths.add(Path(path).parent)
    return paths


def validate_grants(manifest, control):
    # Workspaces, records and coordinator registries all live under the
    # control directory, so protecting it covers every trusted path.
    protected = [control]
    for key in ("record_root", "tart_home"):
        if manifest.get("builder", {}).get(key):
            protected.append(Path(manifest["builder"][key]).resolve())
    for value in manifest["policy"]["read"] + manifest["policy"]["write"]:
        path = Path(value)
        for target in protected:
            if path == target or path in target.parents or target in path.parents:
                raise SessionError(
                    "A filesystem grant overlaps trusted session or builder records"
                )
    validate_transport_grants(manifest)
    for forbidden in (
        "/nix/var/nix/daemon-socket",
        "/run",
        "/var/run",
        "/private/var/run",
    ):
        for value in manifest["policy"]["read"] + manifest["policy"]["write"]:
            path = Path(value)
            target = Path(forbidden)
            if path == target or path in target.parents:
                raise SessionError("A filesystem grant exposes host service sockets")


def validate_transport_grants(manifest):
    for value in manifest["policy"]["write"]:
        path = Path(value)
        for target in transport_directories(manifest):
            if path == target or path in target.parents or target in path.parents:
                raise SessionError(
                    "A write grant overlaps trusted service sockets; use the private session TMPDIR"
                )


def workspace_root(manifest):
    root = Path(manifest["workspace"]["session_root"])
    info = root.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or [info.st_dev, info.st_ino] != manifest["workspace"]["root_identity"]
    ):
        raise SessionError("Session workspace root was replaced")
    return root


def trusted_layout(manifest):
    # Seatbelt write denies match resolved paths, so a parent directory a
    # previous run of this session replaced with a symlink lets it plant
    # files under a spelling no deny covers, such as a swapped `.PI` or
    # `runtime/agent`. The reclaim in prepare() walks the agent directory
    # with O_NOFOLLOW and already refuses a swapped runtime/agent as a bare
    # OSError; this names every directory pi loads trusted material from
    # and refuses a swap of any of them before pi starts. A first launch
    # passes with none of the optional directories present.
    root = workspace_root(manifest)
    workspace = Path(manifest["workspace"]["workspace"])
    for label, path, required in (
        ("workspace", workspace, True),
        ("private Git storage", Path(manifest["workspace"]["common_dir"]), True),
        ("project configuration", workspace / ".pi", False),
        ("session runtime", root / "runtime", False),
        ("agent state", root / "runtime" / "agent", False),
    ):
        try:
            info = path.lstat()
        except FileNotFoundError:
            if required:
                raise SessionError(
                    f"Session {label} directory is missing: {path}"
                ) from None
            continue
        if not stat.S_ISDIR(info.st_mode):
            raise SessionError(f"Session {label} directory was replaced: {path}")
    return root


def prepare(config, manifest, relay):
    root = trusted_layout(manifest)
    runtime = root / "runtime"
    for name in PLANTED_AGENT_NAMES:
        safe_clear(root, "runtime/agent/" + name)
    for name in ("home", "tmp", "cache", "state", "sessions"):
        safe_write(root, f"runtime/{name}/.pi-runtime", b"")
    settings = read_json(config["settingsFile"]) if config["settingsFile"] else {}
    try:
        preferences = json.loads(safe_read(root, "runtime/agent/settings.json"))
    except FileNotFoundError:
        preferences = {}
    for key in (
        "theme",
        "quietStartup",
        "showThinkingBlock",
        "defaultThinkingLevel",
        "lastChangelogVersion",
    ):
        if key in preferences:
            settings[key] = preferences[key]
    settings.update(
        {
            "packages": [],
            "extensions": [str(Path(config["runtimeSource"]) / "extensions")]
            if config["runtimeSource"]
            else [],
            "enableSkillCommands": True,
        }
    )
    safe_write(
        root, "runtime/agent/settings.json", (json.dumps(settings) + "\n").encode()
    )
    safe_write(
        root, "runtime/agent/models.json", (json.dumps(relay.catalog) + "\n").encode()
    )
    safe_write(root, "runtime/agent/auth.json", b"{}\n")
    if config["runtimeSource"]:
        source = Path(config["runtimeSource"])
        for name in ("agents", "themes", "grants", "skills"):
            if not (source / name).is_dir():
                continue
            for path in (source / name).rglob("*"):
                if path.is_file():
                    safe_write(
                        root,
                        "runtime/agent/" + str(path.relative_to(source)),
                        path.read_bytes(),
                    )
        for name in ("keybindings.json", "AGENTS.md"):
            if (source / name).is_file():
                safe_write(root, "runtime/agent/" + name, (source / name).read_bytes())
    return runtime


def coordinator(config, manifest, control, executable):
    if not config["coordinatorDaemon"]:
        raise SessionError("Coordinator support is not configured")
    identity = manifest["coordinator_id"]
    if not ID.fullmatch(identity):
        raise SessionError("Invalid coordinator ID")
    coord = control / "coordinators" / identity
    coord.parent.mkdir(mode=0o700, exist_ok=True)
    policy_file = control / "records" / manifest["id"] / "manifest.json"
    write_json(policy_file, manifest)
    subprocess.run(
        [
            config["coordinatorDaemon"],
            "init",
            "--coord-dir",
            str(coord),
            "--repo",
            manifest["workspace"]["workspace"],
            "--launcher",
            executable,
            "--policy",
            str(policy_file),
        ],
        check=True,
        env={**os.environ, "PATH": config["path"]},
    )
    result = subprocess.run(
        [config["coordinatorDaemon"], "credentials", str(coord)],
        check=True,
        stdout=subprocess.PIPE,
        env={**os.environ, "PATH": config["path"]},
    )
    value = json.loads(result.stdout)
    manifest["coordinator"] = {
        "socket": value["socket"],
        "token": value["token"],
        "id": identity,
        "role": "main",
    }


def run(config, manifest, args, home):
    catalog, auth, tool_credentials = credentials(
        config, manifest, home, include_tools=True
    )
    spec = importlib.util.spec_from_file_location("relay", config["relayModule"])
    relay_module = importlib.util.module_from_spec(spec)
    sys.modules["relay"] = relay_module
    spec.loader.exec_module(relay_module)
    with ExitStack() as services:
        relay = services.enter_context(
            relay_module.start_relay(
                catalog,
                auth,
                allowed_models=manifest["policy"].get("allowed_models"),
                allow_private_hosts=config.get("privateProviderHosts", []),
                tool_credentials=tool_credentials,
            )
        )
        runtime = prepare(config, manifest, relay)
        environment = child_environment(config, manifest, home, runtime)
        environment.update(relay.tool_env)
        if manifest["policy"]["nix"]:
            from build_service import BuildService

            build = services.enter_context(
                BuildService(
                    manifest["builder"],
                    manifest["workspace"],
                    Path(manifest["workspace"]["record_root"]) / "builds",
                    config["builderModule"],
                )
            )
            safe_write(
                workspace_root(manifest),
                "runtime/build.json",
                (json.dumps(build.client) + "\n").encode(),
            )
            # bin/nix reads this name (build_client.py).
            environment["ALAMODE_BUILD_CLIENT"] = str(runtime / "build.json")
            environment["PATH"] = (
                str(Path(config["buildClient"]).parent) + ":" + environment["PATH"]
            )
            manifest = {**manifest, "build_socket": build.socket}
        pi_args = list(config["piArgs"]) + args
        session_file = str(runtime / "sessions/main.jsonl")
        if (
            not Path(session_file).exists()
            and "--model" not in pi_args
            and manifest.get("seats", {}).get("ALAMODE_SESSION_MODEL")
        ):
            pi_args = ["--model", manifest["seats"]["ALAMODE_SESSION_MODEL"], *pi_args]
        if "--session" not in pi_args and "--no-session" not in pi_args:
            pi_args = ["--session", session_file, *pi_args]
        return execute(
            config,
            manifest,
            [config["pi"], *pi_args, "--no-approve"],
            environment,
            runtime,
            relay.port,
        )


def execute(config, manifest, arguments, environment, runtime, relay_port=0):
    workspace_root(manifest)
    validate_transport_grants(manifest)
    payload = {
        "argv": arguments,
        "shell": config["shell"],
        "cwd": manifest["workspace"]["workspace"],
        "env": environment,
        "sandbox": sandbox_policy(config, manifest, runtime, relay_port),
        "web": manifest["policy"]["web"],
        "localPorts": [
            *([relay_port] if relay_port else []),
            *manifest["policy"]["listen"],
            *manifest.get("resources", {}).get("forge", {}).get("local_ports", []),
        ],
        "listenPorts": manifest["policy"]["listen"],
    }
    with (
        tempfile.TemporaryDirectory(
            prefix="n-", dir=directory(Path("/tmp") / f"alamode-network-{os.getuid()}")
        ) as proxy_directory,
        tempfile.TemporaryFile(mode="w+") as stream,
    ):
        json.dump(payload, stream)
        stream.flush()
        stream.seek(0)
        runner_env = {
            key: value
            for key, value in environment.items()
            if key in SAFE_ENV or key in ("PATH", "HOME", "TMPDIR")
        }
        runner_env["TMPDIR"] = proxy_directory
        # srt replaces the child's TMPDIR with this process's
        # CLAUDE_CODE_TMPDIR, or else /tmp/claude, which the read policy
        # denies (sandbox-runtime 0.0.78 sandbox-utils.js,
        # generateProxyEnvVars).
        runner_env["CLAUDE_CODE_TMPDIR"] = environment["TMPDIR"]
        process = subprocess.Popen(
            [config["node"], config["sandboxRunner"], str(stream.fileno())],
            pass_fds=(stream.fileno(),),
            env=runner_env,
        )
        previous = signal.signal(signal.SIGINT, lambda *_: None)
        try:
            return process.wait()
        finally:
            signal.signal(signal.SIGINT, previous)
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def export_session(manifest):
    """Seal a session's committed work out of private storage, host-side.

    Extraction is data-only, so it cannot depend on the runtime that
    recorded the session: the wrapper is rebuilt between launches as a
    matter of course, and a rebuild must never strand committed work.
    Nothing from the session executes on the way out either: the
    session's HEAD is read by the no-symlink ref reader, a fresh staging
    repo with its own trusted config reaches the session's objects only
    through the alternate-object environment, the sealed bundle lands in
    the session root through the no-symlink writer, and admission
    re-verifies it (ancestry from the recorded base, commit bounds,
    protected and trust-gated content) exactly as it reviews every other
    proposal.
    """
    root = trusted_layout(manifest)
    session_workspace = manifest["workspace"]
    base = session_workspace["snapshot_commit"]
    bare = Path(session_workspace["common_dir"])
    tip = workspace._source_head(bare, bare)
    identity = secrets.token_hex(12)
    exports = directory(Path(session_workspace["record_root"]) / "exports")
    staging = exports / (identity + "-staging.git")
    try:
        workspace._init_bare(staging, base)
        alternates = {"GIT_ALTERNATE_OBJECT_DIRECTORIES": str(bare / "objects")}
        workspace._git(
            staging, "update-ref", "refs/heads/alamode-export", tip, extra=alternates
        )
        workspace._git(staging, "symbolic-ref", "HEAD", "refs/heads/alamode-export")
        sealed = staging / "sealed.bundle"
        try:
            workspace._git(
                staging,
                "bundle",
                "create",
                str(sealed),
                "HEAD",
                "^" + base,
                extra=alternates,
            )
        except workspace.WorkspaceError as error:
            # The git detail goes to stderr as the sandboxed child's output
            # once did; the refusal the caller sees stays the same words.
            print(f"alamode: {error}", file=sys.stderr)
            raise SessionError(
                "Export failed; commit changes inside the session before exporting"
            ) from None
        if sealed.stat().st_size > workspace.MAX_BUNDLE_BYTES:
            raise SessionError("Exported history exceeds the bundle size limit")
        bundle = root / "runtime" / ("export-" + identity + ".bundle")
        safe_write(root, "runtime/export-" + identity + ".bundle", sealed.read_bytes())
        admitted = workspace.admit_bundle(
            session_workspace, bundle, exports / identity, tip, identity
        )
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    reference = "refs/review/" + identity
    exported = Path(admitted["quarantine"]) / "export.bundle"
    workspace._git(
        Path(admitted["quarantine"]) / "repository.git",
        "bundle",
        "create",
        str(exported),
        reference,
    )
    print(
        json.dumps(
            {
                "session": manifest["id"],
                "bundle": str(exported),
                "ref": reference,
                "base": base,
                "tip": tip,
                # Context files load in the human's own pi with no trust
                # decision, so a merge that carries them must be reviewed as
                # model-authored instructions, not documentation.
                "context_files": admitted.get("context_files", []),
                "source": manifest["workspace"]["source"],
                "branch": manifest["workspace"]["branch"],
            },
            indent=2,
        )
    )
    return 0


def information(config, flag):
    with tempfile.TemporaryDirectory(prefix="alamode-info-") as home:
        environment = {
            "PATH": config["path"],
            "HOME": home,
            "PI_CODING_AGENT_DIR": str(Path(home) / "agent"),
            "PI_SKIP_VERSION_CHECK": "1",
            "PI_OFFLINE": "1",
            "PI_TELEMETRY": "0",
        }
        return subprocess.run(
            [
                config["pi"],
                "--no-extensions",
                "-nc",
                "-ns",
                "-np",
                "-na",
                "--offline",
                flag,
            ],
            cwd=home,
            env=environment,
        ).returncode


def source_repository(cwd):
    for candidate in (cwd, *cwd.parents):
        if (candidate / ".git").exists() or (candidate / ".git").is_symlink():
            return candidate
    return None


def coordinator_table(control):
    root = control / "coordinators"
    entries = []
    for path in sorted(root.glob("*/broker.json")):
        data = read_json(path)
        state, agents = "stopped", "-"
        address = data.get("socket", "")
        if address and Path(address).exists():
            try:
                status = request(address, data["token"], {"op": "status"}, timeout=2)
                state = "live"
                agents = str(len(status.get("agents", [])))
            except (OSError, ValueError):
                state = "stopped"
        entries.append((path.parent.name, state, agents, data.get("repo_dir", "")))
    if not entries:
        print("alamode: no coordinators recorded")
        return 0
    width = max(len("COORDINATOR"), *(len(entry[0]) for entry in entries))
    print(f"{'COORDINATOR':<{width}}  STATE    AGENTS  REPO")
    for identifier, state, agents, repository in entries:
        print(f"{identifier:<{width}}  {state:<8}  {agents:<6}  {repository}")
    return 0


def stop_coordinator(control, identifier):
    if not ID.fullmatch(identifier):
        raise SessionError("Invalid coordinator ID")
    record = control / "coordinators" / identifier / "broker.json"
    if not record.exists():
        raise SessionError(f"No coordinator recorded under {identifier}")
    data = read_json(record)
    try:
        request(
            data["socket"],
            data["token"],
            {"op": "shutdown", "id": secrets.token_hex(8)},
            timeout=10,
        )
    except (OSError, ValueError) as error:
        raise SessionError(
            f"Coordinator {identifier} is not reachable: {error}"
        ) from error
    print(
        f"alamode: coordinator {identifier} stopped; agents keep running; "
        f"alamode coord attach {identifier} revives it"
    )
    return 0


def main(argv=None):
    os.umask(0o077)

    def terminate(signum, _frame):
        raise SessionError(f"Session stopped by signal {signum}")

    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, terminate)
    argv = list(sys.argv[1:] if argv is None else argv)
    configuration_path = str(Path(argv.pop(0)).resolve())
    config = read_json(configuration_path)
    config["path"] += (
        ":/etc/profiles/per-user/" + pwd.getpwuid(os.getuid()).pw_name + "/bin"
    )
    executable = argv.pop(0)
    if argv in (["--version"], ["-v"]):
        return information(config, "--version")
    verb = argv[0] if argv and argv[0] in VERBS else None
    if verb in ("delegate", "seats"):
        binary = config.get(verb + "Bin", "")
        if not binary:
            raise SessionError(f"alamode {verb} is not configured on this host")
        os.execv(binary, [binary, *argv[1:]])
    front, engine_args = split_boundary(argv[1:] if verb else argv)
    if "--help" in front or "-h" in front:
        print(HELP)
        return 0

    resume_id = None
    export_id = None
    inspect_id = None
    list_sessions = False
    list_coordinators = False
    coordinator_new = False
    coordinator_start = False
    attach_id = None
    stop_id = None
    grant_part = front

    if verb == "resume":
        if front and not front[0].startswith("-"):
            resume_id = front.pop(0)
        grant_part = front
    elif verb == "sessions":
        if engine_args:
            raise SessionError("sessions takes no engine arguments")
        if not front:
            list_sessions = True
        elif (
            len(front) == 2
            and front[0] in ("show", "export")
            and not front[1].startswith("-")
        ):
            if front[0] == "show":
                inspect_id = front[1]
            else:
                export_id = front[1]
        else:
            raise SessionError("sessions takes: nothing to list, show ID, or export ID")
        grant_part = []
    elif verb == "coord":
        sub = front[0] if front and not front[0].startswith("-") else None
        if sub == "attach":
            if len(front) != 2 or front[1].startswith("-"):
                raise SessionError("coord attach takes one coordinator ID")
            attach_id = front[1]
            grant_part = front[2:]
        elif sub == "start":
            if engine_args:
                raise SessionError(
                    "coord start opens no session; engine arguments do not apply"
                )
            coordinator_start = True
            grant_part = front[1:]
        elif sub == "ls":
            if len(front) != 1 or engine_args:
                raise SessionError("coord ls takes no arguments")
            list_coordinators = True
            grant_part = []
        elif sub == "stop":
            if len(front) != 2 or front[1].startswith("-") or engine_args:
                raise SessionError("coord stop takes one coordinator ID")
            stop_id = front[1]
            grant_part = []
        else:
            coordinator_new = True
            grant_part = front

    home = Path.home()
    control = directory(home / ".local/state/alamode")
    records = directory(control / "records")
    sessions = directory(control / "workspaces")
    try:
        # After the argument checks, so --help and --version stay read-only.
        pin_store_roots(config, control=control)
    except (OSError, KeyError):
        pass  # A best-effort root never stops a launch.
    options = parse(grant_part, config)
    if verb == "resume" and resume_id is None:
        candidates = sorted(
            records.glob("*/manifest.json"), key=lambda path: path.stat().st_mtime
        )
        if not candidates:
            raise SessionError("No sessions recorded yet")
        resume_id = candidates[-1].parent.name
    if resume_id or attach_id or options.managed_manifest:
        refuse_grant_changes(options, config)
    if list_coordinators:
        return coordinator_table(control)
    if stop_id is not None:
        return stop_coordinator(control, stop_id)
    if list_sessions:
        for path in sorted(records.glob("*/manifest.json")):
            record = read_json(path)
            print(
                json.dumps(
                    {
                        "id": record["id"],
                        "workspace": record["workspace"]["workspace"],
                        "source": record["workspace"]["source"],
                    }
                )
            )
        return 0
    if inspect_id:
        if not ID.fullmatch(inspect_id):
            raise SessionError("Invalid session ID")
        record = read_json(records / inspect_id / "manifest.json")
        print(
            json.dumps(
                {
                    key: record[key]
                    for key in ("id", "policy", "workspace", "configuration")
                },
                indent=2,
            )
        )
        return 0
    if attach_id:
        if not ID.fullmatch(attach_id) or not config["coordinatorDaemon"]:
            raise SessionError("Invalid or unavailable coordinator")
        coord = control / "coordinators" / attach_id
        result = subprocess.run(
            [config["coordinatorDaemon"], "credentials", str(coord)],
            check=True,
            stdout=subprocess.PIPE,
        )
        resume_id = json.loads(result.stdout)["session"]
    if options.managed_manifest:
        manifest_path = Path(options.managed_manifest).resolve(strict=True)
        if control not in manifest_path.parents:
            raise SessionError(
                "Managed manifests must be issued by the trusted coordinator"
            )
        manifest = read_json(manifest_path)
    elif resume_id or export_id:
        identity = resume_id or export_id
        if not ID.fullmatch(identity):
            raise SessionError("Invalid session ID")
        manifest_path = records / identity / "manifest.json"
        manifest = read_json(manifest_path)
        if resume_id:
            # Resume re-admits this session through the current build; export
            # is data-only and takes the same manifest from any build.
            require_recorded_runtime(manifest, configuration_path)
    else:
        identity = time.strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(4)
        grants = policy(options, config, home)
        if config["catalogFile"]:
            grants["allowed_models"], grants["catalog_scope"] = catalog_scope(
                read_json(expand(config["catalogFile"], home)), config, grants["local"]
            )
        held = seats(config, home)
        if grants["local"]:
            if not grants.get("allowed_models"):
                raise SessionError("--local found no model with a loopback baseUrl")
            held, dropped = local_seats(held, grants)
            if dropped:
                print(
                    "alamode: --local dropped seats on a non-local model: "
                    + ", ".join(dropped),
                    file=sys.stderr,
                )
        manifest = {
            "version": 1,
            "id": identity,
            "policy": grants,
            "seats": held,
            "configuration": configuration_path,
            "launcher": executable,
        }
        if grants["nix"]:
            manifest["builder"] = read_json(expand(config["builder"], home))
        validate_grants(manifest, control)
        source = source_repository(Path.cwd())
        if source:
            manifest["workspace"] = workspace.create(
                source,
                sessions / identity,
                "alamode/" + identity,
                record_root=records / identity,
            )
        else:
            manifest["workspace"] = workspace.create_empty(
                sessions / identity,
                "alamode/" + identity,
                record_root=records / identity,
            )
        manifest_path = records / identity / "manifest.json"
        if coordinator_new or coordinator_start:
            manifest["coordinator_id"] = identity
        write_json(manifest_path, manifest)
    validate_grants(manifest, control)
    lock_path = manifest_path.parent / "launch.lock"
    with lock_path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise SessionError("This session is already running") from error
        if export_id:
            return export_session(manifest)
        if manifest.get("coordinator_id"):
            coordinator(config, manifest, control, executable)
            write_json(manifest_path, manifest)
        if coordinator_start:
            print(
                json.dumps(
                    {
                        "socket": manifest["coordinator"]["socket"],
                        "token": manifest["coordinator"]["token"],
                        "coordinator": manifest["coordinator"]["id"],
                        "session": manifest["id"],
                        "workspace": manifest["workspace"]["workspace"],
                    }
                )
            )
            return 0
        print(
            f"alamode: session {manifest['id']}\nalamode: workspace {manifest['workspace']['workspace']}",
            file=sys.stderr,
        )
        return run(config, manifest, engine_args, home)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (
        SessionError,
        workspace.WorkspaceError,
        OSError,
        ValueError,
        subprocess.SubprocessError,
    ) as error:
        print(f"alamode: {error}", file=sys.stderr)
        sys.exit(1)
