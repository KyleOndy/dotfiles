"""Trusted session admission. Workload configuration never grants host authority."""

import argparse
from contextlib import ExitStack
import fcntl
import hashlib
import importlib.util
import json
import os
import pwd
from pathlib import Path
import re
import secrets
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).parent))
from common import socket_directory
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


def parse(args, config):
    parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--resume-session")
    target.add_argument("--export-session")
    target.add_argument("--inspect-session")
    target.add_argument("--list-sessions", action="store_true")
    target.add_argument("--managed-manifest")
    target.add_argument("--coordinator", nargs="?", const="new")
    parser.add_argument("--start-coordinator", action="store_true")
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
    parser.add_argument("--session-help", action="store_true")
    for name in config["bundles"]:
        parser.add_argument(
            "--allow-" + name, action="store_true", dest="bundle_" + name
        )
    options, pi_args = parser.parse_known_args(args)
    for arg in pi_args:
        if arg.startswith("--allow-") or arg in (
            "--no-sandbox",
            "--resume",
            "--continue",
            "-r",
            "-c",
        ):
            raise SessionError(
                f"Unsupported authority or transcript flag {arg}; use --session-help"
            )
    if (
        options.managed_manifest
        or options.resume_session
        or options.export_session
        or (options.coordinator and options.coordinator != "new")
    ):
        changed = (
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
            or options.no_git_write
            or options.allow_git_write
            or any(getattr(options, "bundle_" + name) for name in config["bundles"])
        )
        if changed:
            raise SessionError(
                "Resume uses the recorded grants; start a new session to change authority"
            )
    return options, pi_args


def policy(options, config, home):
    result = {
        "web": options.web,
        "domains": list(config["domains"]) + options.allow,
        "read": list(config["readPaths"]) + options.allow_read + options.allow_rw,
        "write": list(config["writePaths"]) + options.allow_write + options.allow_rw,
        "listen": list(config.get("listenPorts", [])) + options.listen,
        "trustd": options.allow_trustd or config["allowTrustd"],
        "clipboard": options.allow_clipboard,
        "git_write": not options.no_git_write
        and (options.allow_git_write or config.get("gitWrite", True)),
        "nix": options.allow_nix or config["allowNix"],
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


def catalog_scope(catalog, config):
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
            models.append(
                {
                    "model": provider + "/" + model["id"],
                    "api": effective.get("api"),
                    "baseUrl": effective.get("baseUrl"),
                }
            )
    wire = json.dumps(models, sort_keys=True, separators=(",", ":")).encode()
    return [model["model"] for model in models], hashlib.sha256(wire).hexdigest()


def seats(config, home):
    values = {}
    path = config.get("seatsFile")
    if path:
        for line in Path(expand(path, home)).read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, separator, value = line.partition("=")
            if not separator or not re.fullmatch(r"PI_[A-Z0-9_]*MODEL[A-Z0-9_]*", key):
                raise SessionError("Invalid model seat assignment")
            parsed = shlex.split(value, comments=True)
            if len(parsed) != 1:
                raise SessionError("A model seat must have one value")
            values[key] = parsed[0]
    values.update(
        {
            key: value
            for key, value in os.environ.items()
            if re.fullmatch(r"PI_[A-Z0-9_]*MODEL[A-Z0-9_]*", key)
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
            "Configure modelsJson or modelsJsonFile with explicit model definitions before starting Pi"
        )
    catalog = read_json(expand(catalog_path, home))
    _, digest = catalog_scope(catalog, config)
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
# its in-process guards load secret-guard.json (docs/pi-sandbox-audit.md,
# findings 1-6). bin and npm shadow the tools pi and its extensions run
# (getToolPath checks bin before PATH). extensions, agents, themes, grants and
# skills are recopied from the store below, so clearing them first also drops
# planted extras a plain recopy would leave beside the deployed files.
# Everything pi may legitimately write for itself survives: settings.json,
# models.json and auth.json are rewritten, and secret-guard-violations.log,
# sessions, task-logs and job-logs are pi's own records.
PLANTED_AGENT_NAMES = (
    "mcp.json",
    "mcp-auth.json",
    "trust.json",
    "models-store.json",
    "secret-guard.json",
    "extensions",
    "agents",
    "themes",
    "grants",
    "skills",
    "bin",
    "npm",
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
            "PI_SESSION_ID": manifest["id"],
            "PI_REAL_BIN": config["pi"],
            "PI_SKIP_VERSION_CHECK": "1",
            "PI_TELEMETRY": "0",
            "PI_GRANTS": ",".join(grants),
            "PI_AVAILABLE_GRANTS": ",".join(
                [
                    *config["bundles"],
                    "web",
                    "nix",
                    "forge",
                    "clipboard",
                    "trustd",
                    "git-write",
                ]
            ),
            "PI_TRUSTED_PROVIDERS": ",".join(config["trustedProviders"]),
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
            PI_COORD_SOCKET=coordinator["socket"],
            PI_COORD_TOKEN=coordinator["token"],
            PI_COORD_ID=coordinator["id"],
            PI_COORD_ROLE=coordinator["role"],
        )
        if coordinator.get("agent"):
            env["PI_COORD_AGENT"] = coordinator["agent"]
        if manifest["policy"].get("forge"):
            env["PI_COORD_FORGE"] = "1"
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
    paths = {socket_directory(), Path("/tmp").resolve() / f"pi-network-{os.getuid()}"}
    for path in (
        manifest.get("coordinator", {}).get("socket"),
        manifest.get("build_socket"),
    ):
        if path:
            paths.add(Path(path).parent)
    return paths


def validate_grants(manifest, control):
    protected = [control, control.with_name("pi-workspaces")]
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


def prepare(config, manifest, relay):
    root = workspace_root(manifest)
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
    if not config["broker"]:
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
            config["broker"],
            str(coord),
            str(os.getpid()),
            manifest["workspace"]["workspace"],
            executable,
            "--policy",
            str(policy_file),
        ],
        check=True,
        env={**os.environ, "PATH": config["path"]},
    )
    result = subprocess.run(
        [config["broker"], "--credentials", str(coord)],
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
            environment["PI_BUILD_CLIENT"] = str(runtime / "build.json")
            environment["PATH"] = (
                str(Path(config["buildClient"]).parent) + ":" + environment["PATH"]
            )
            manifest = {**manifest, "build_socket": build.socket}
        pi_args = list(config["piArgs"]) + args
        session_file = str(runtime / "sessions/main.jsonl")
        if (
            not Path(session_file).exists()
            and "--model" not in pi_args
            and manifest.get("seats", {}).get("PI_SESSION_MODEL")
        ):
            pi_args = ["--model", manifest["seats"]["PI_SESSION_MODEL"], *pi_args]
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
            prefix="n-", dir=directory(Path("/tmp") / f"pi-network-{os.getuid()}")
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


def export_session(config, manifest, home):
    root = Path(manifest["workspace"]["session_root"])
    runtime = root / "runtime"
    identity = secrets.token_hex(12)
    bundle = runtime / ("export-" + identity + ".bundle")
    tip_file = "runtime/export-" + identity + ".tip"
    base = manifest["workspace"]["snapshot_commit"]
    command = (
        "git bundle create "
        + shlex.quote(str(bundle))
        + " HEAD ^"
        + base
        + " && git rev-parse HEAD > "
        + shlex.quote(str(root / tip_file))
    )
    environment = child_environment(config, manifest, home, runtime)
    code = execute(
        config, manifest, [config["shell"], "-c", command], environment, runtime
    )
    if code:
        raise SessionError(
            "Export failed; commit changes inside the session before exporting"
        )
    tip = safe_read(root, tip_file, limit=128).decode().strip()
    exports = directory(Path(manifest["workspace"]["record_root"]) / "exports")
    admitted = workspace.admit_bundle(
        manifest["workspace"], bundle, exports / identity, tip, identity
    )
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
                "source": manifest["workspace"]["source"],
                "branch": manifest["workspace"]["branch"],
            },
            indent=2,
        )
    )
    return 0


def information(config, flag):
    with tempfile.TemporaryDirectory(prefix="pi-info-") as home:
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
    options, args = parse(argv, config)
    if options.session_help or argv in (["--help"], ["-h"]):
        print("""pi [--coordinator[=ID]] [--web] [--allow HOST] [--listen PORT]
   [--allow-read PATH] [--allow-rw PATH] [--allow-TOOLCHAIN]
   [--allow-nix] [--allow-forge] [--allow-clipboard] [pi arguments]
pi --resume-session ID [pi arguments]
pi --list-sessions | --inspect-session ID | --export-session ID

Launches snapshot the current repository into private Git storage.
Outside a repository, launches use an empty private scratch workspace.
Grants persist on resume. Provider credentials stay in the host relay.
--allow-nix requires a configured isolated Darwin builder.
--export-session validates committed changes and prints a review bundle.
--start-coordinator starts a service without opening the UI.
--no-git-write denies writes to the private Git object and ref storage.""")
        return information(config, "--help") if not options.session_help else 0
    home = Path.home()
    control = directory(home / ".local/state/pi-control")
    records = directory(control / "records")
    sessions = directory(home / ".local/state/pi-workspaces")
    if options.coordinator and options.coordinator != "new":
        if not ID.fullmatch(options.coordinator) or not config["broker"]:
            raise SessionError("Invalid or unavailable coordinator")
        coord = control / "coordinators" / options.coordinator
        result = subprocess.run(
            [config["broker"], "--credentials", str(coord)],
            check=True,
            stdout=subprocess.PIPE,
        )
        options.resume_session = json.loads(result.stdout)["session"]
    if options.list_sessions:
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
    if options.inspect_session:
        if not ID.fullmatch(options.inspect_session):
            raise SessionError("Invalid session ID")
        record = read_json(records / options.inspect_session / "manifest.json")
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
    if options.managed_manifest:
        manifest_path = Path(options.managed_manifest).resolve(strict=True)
        if control not in manifest_path.parents:
            raise SessionError(
                "Managed manifests must be issued by the trusted coordinator"
            )
        manifest = read_json(manifest_path)
    elif options.resume_session or options.export_session:
        identity = options.resume_session or options.export_session
        if not ID.fullmatch(identity):
            raise SessionError("Invalid session ID")
        manifest_path = records / identity / "manifest.json"
        manifest = read_json(manifest_path)
        if manifest["configuration"] != configuration_path:
            raise SessionError(
                "Session was created by a different runtime; use its recorded launcher or start a new session"
            )
    else:
        identity = time.strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(4)
        grants = policy(options, config, home)
        if config["catalogFile"]:
            grants["allowed_models"], grants["catalog_scope"] = catalog_scope(
                read_json(expand(config["catalogFile"], home)), config
            )
        manifest = {
            "version": 1,
            "id": identity,
            "policy": grants,
            "seats": seats(config, home),
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
                "pi/" + identity,
                record_root=records / identity,
            )
        else:
            manifest["workspace"] = workspace.create_empty(
                sessions / identity, "pi/" + identity, record_root=records / identity
            )
        manifest_path = records / identity / "manifest.json"
        if options.coordinator or options.start_coordinator:
            manifest["coordinator_id"] = (
                identity if options.coordinator == "new" else options.coordinator
            )
            manifest["coordinator_id"] = manifest["coordinator_id"] or identity
        write_json(manifest_path, manifest)
    validate_grants(manifest, control)
    lock_path = manifest_path.parent / "launch.lock"
    with lock_path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise SessionError("This session is already running") from error
        if options.export_session:
            return export_session(config, manifest, home)
        if manifest.get("coordinator_id"):
            coordinator(config, manifest, control, executable)
            write_json(manifest_path, manifest)
        if options.start_coordinator:
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
            f"pi: session {manifest['id']}\npi: workspace {manifest['workspace']['workspace']}",
            file=sys.stderr,
        )
        return run(config, manifest, args, home)


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
        print(f"pi: {error}", file=sys.stderr)
        sys.exit(1)
