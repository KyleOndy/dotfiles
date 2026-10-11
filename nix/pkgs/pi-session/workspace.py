"""Private Git storage and admission of commits from an untrusted workspace."""

import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile


GIT = shutil.which("git") or "git"
MAX_BUNDLE_BYTES = 256 * 1024 * 1024
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_COMMITS = 1000
OID = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")


class WorkspaceError(RuntimeError):
    pass


def _environment(extra=None):
    env = {
        key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR") if key in os.environ
    }
    env.update(
        GIT_CONFIG_NOSYSTEM="1",
        GIT_CONFIG_GLOBAL="/dev/null",
        GIT_TERMINAL_PROMPT="0",
        GIT_AUTHOR_NAME="Pi workspace",
        GIT_AUTHOR_EMAIL="pi-workspace@localhost",
        GIT_COMMITTER_NAME="Pi workspace",
        GIT_COMMITTER_EMAIL="pi-workspace@localhost",
        LC_ALL="C",
    )
    if extra:
        for key, value in extra.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
    return env


def _git(directory, *args, data=None, extra=None, check=True, output=None):
    command = [
        GIT,
        "--literal-pathspecs",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "commit.gpgsign=false",
        "-c",
        "maintenance.auto=false",
        "--git-dir=" + str(directory),
        *args,
    ]
    try:
        result = subprocess.run(
            command,
            input=data,
            stdout=output or subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=_environment(extra),
            timeout=120,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise WorkspaceError(f"Git could not complete {args[0]}: {error}") from error
    if check and result.returncode:
        message = result.stderr.decode(errors="replace").strip()[:2000]
        raise WorkspaceError(f"Git {args[0]} failed: {message}")
    return result


def _text(directory, *args, **kwargs):
    return _git(directory, *args, **kwargs).stdout.decode().strip()


def _parts(path):
    parts = Path(path).parts
    if (
        not parts
        or any(part in ("", ".", "..") for part in parts)
        or Path(path).is_absolute()
    ):
        raise WorkspaceError(f"Invalid relative path: {path}")
    return parts


def _open_parent(root, relative):
    parts = _parts(relative)
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts[:-1]:
            child = os.open(
                part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor
            )
            os.close(descriptor)
            descriptor = child
        return descriptor, parts[-1]
    except BaseException:
        os.close(descriptor)
        raise


def _stamp(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def _read_entry(root, relative, limit=MAX_FILE_BYTES):
    parent, name = _open_parent(root, relative)
    try:
        info = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if stat.S_ISLNK(info.st_mode):
            return "120000", os.fsencode(os.readlink(name, dir_fd=parent))
        if not stat.S_ISREG(info.st_mode):
            raise WorkspaceError(
                f"Snapshot requires a regular file or symlink: {relative}"
            )
        descriptor = os.open(
            name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent
        )
        with os.fdopen(descriptor, "rb") as stream:
            before = os.fstat(stream.fileno())
            if _stamp(info) != _stamp(before) or before.st_size > limit:
                raise WorkspaceError(
                    f"Snapshot file changed or exceeds {limit} bytes: {relative}"
                )
            contents = stream.read(limit + 1)
            if len(contents) > limit or _stamp(before) != _stamp(
                os.fstat(stream.fileno())
            ):
                raise WorkspaceError(f"Snapshot file changed while reading: {relative}")
        return ("100755" if info.st_mode & 0o111 else "100644"), contents
    finally:
        os.close(parent)


def _source_metadata(source):
    dotgit = source / ".git"
    if dotgit.is_symlink():
        raise WorkspaceError("Source .git must not be a symlink")
    if dotgit.is_dir():
        own = dotgit
    else:
        try:
            pointer = dotgit.read_text().strip()
        except OSError as error:
            raise WorkspaceError("Choose a Git working tree as the source") from error
        if not pointer.startswith("gitdir: "):
            raise WorkspaceError("Invalid source .git pointer")
        own = (source / pointer[8:]).resolve()
    common_file = own / "commondir"
    common = (
        (own / common_file.read_text().strip()).resolve()
        if common_file.exists()
        else own
    )
    objects = common / "objects"
    if objects.is_symlink() or not objects.is_dir():
        raise WorkspaceError("Source object directory must be a real directory")
    for directory, dirs, files in os.walk(objects, followlinks=False):
        for name in dirs + files:
            if (Path(directory) / name).is_symlink():
                raise WorkspaceError("Source object storage contains a symlink")
    alternates = objects / "info" / "alternates"
    if alternates.exists() and alternates.stat().st_size:
        raise WorkspaceError(
            "Source borrows objects; create a self-contained source before starting Pi"
        )
    return own, common, objects


def _source_head(own, common):
    value = (own / "HEAD").read_text().strip()
    for _ in range(8):
        if OID.fullmatch(value):
            return value
        if not value.startswith("ref: refs/"):
            break
        ref = value[5:]
        _parts(ref)
        try:
            _, content = _read_entry(common, ref, 1024)
            value = content.decode().strip()
        except FileNotFoundError:
            packed = common / "packed-refs"
            if packed.exists():
                for line in packed.read_text().splitlines():
                    if line.endswith(" " + ref) and OID.fullmatch(
                        line.split(" ", 1)[0]
                    ):
                        return line.split(" ", 1)[0]
            break
    raise WorkspaceError("Source HEAD must resolve to an existing commit")


def _init_bare(directory, base):
    directory.mkdir(mode=0o700)
    _git(
        directory,
        "init",
        "--bare",
        "--quiet",
        "--object-format=" + ("sha256" if len(base) == 64 else "sha1"),
    )


def _attributes(directory, paths):
    if not paths:
        return {}
    data = b"\0".join(os.fsencode(path) for path in paths) + b"\0"
    fields = _git(
        directory, "check-attr", "--cached", "-z", "--stdin", "filter", data=data
    ).stdout.split(b"\0")
    attributes = {}
    for offset in range(0, len(fields) - 1, 3):
        path = os.fsdecode(fields[offset])
        attributes[path] = os.fsdecode(fields[offset + 2])
    return attributes


def _protected(directory, paths):
    return {
        path
        for path, value in _attributes(directory, paths).items()
        if value.startswith("git-crypt") or path.startswith(".git-crypt/")
    }


def _tracked(directory):
    entries = {}
    for record in _git(directory, "ls-files", "--stage", "-z").stdout.split(b"\0"):
        if record:
            metadata, path = record.split(b"\t", 1)
            mode, oid, stage = metadata.split()
            if stage != b"0":
                raise WorkspaceError("Source snapshot has unresolved index entries")
            entries[os.fsdecode(path)] = (mode.decode(), oid.decode())
    return entries


def _snapshot(directory, source, base, own, common):
    _git(directory, "read-tree", base)
    tracked = _tracked(directory)
    # Query configuration as data only. Source hooks, filters and fsmonitor
    # must never run while enumerating the human's untracked files.
    configured = _git(
        own,
        "config",
        "--path",
        "--null",
        "--get",
        "core.excludesFile",
        check=False,
        extra={
            key: os.environ.get(key)
            for key in (
                "GIT_CONFIG_GLOBAL",
                "GIT_CONFIG_SYSTEM",
                "GIT_CONFIG_NOSYSTEM",
                "XDG_CONFIG_HOME",
            )
        },
    )
    if configured.returncode not in (0, 1):
        raise WorkspaceError(
            "Cannot read source ignore configuration safely; repair Git configuration before starting Pi"
        )
    if configured.returncode == 0:
        global_exclude = Path(os.fsdecode(configured.stdout.rstrip(b"\0")))
        if not global_exclude.is_absolute():
            global_exclude = source / global_exclude
    else:
        global_exclude = (
            Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
            / "git"
            / "ignore"
        )
    snapshot_exclude = directory / "info" / "pi-global-exclude"
    snapshot_exclude.write_bytes(b"")
    if global_exclude.exists():
        target = global_exclude.resolve(strict=True)
        _, contents = _read_entry(target.parent, target.name)
        snapshot_exclude.write_bytes(contents)
    _git(directory, "config", "core.excludesFile", str(snapshot_exclude))
    exclude = common / "info" / "exclude"
    if exclude.is_file():
        mode, contents = _read_entry(common, "info/exclude")
        if mode == "120000":
            raise WorkspaceError("Source info/exclude must not be a symlink")
        (directory / "info" / "exclude").write_bytes(contents)
    indexed = _git(
        directory, "ls-files", "-z", extra={"GIT_INDEX_FILE": str(own / "index")}
    ).stdout.split(b"\0")
    untracked = _git(
        directory,
        "--work-tree=" + str(source),
        "ls-files",
        "--others",
        "--exclude-standard",
        "-z",
    ).stdout.split(b"\0")
    paths = sorted(
        set(tracked) | {os.fsdecode(path) for path in untracked + indexed if path}
    )
    protected = _protected(directory, paths)
    for path in paths:
        if Path(path).name == ".gitattributes":
            try:
                mode, contents = _read_entry(source, path)
            except FileNotFoundError:
                _git(directory, "update-index", "--force-remove", "--", path)
                continue
            oid = _text(directory, "hash-object", "-w", "--stdin", data=contents)
            _git(directory, "update-index", "--add", "--cacheinfo", mode, oid, path)
    protected.update(_protected(directory, paths))
    skipped = sorted(
        path
        for path in paths
        if path in protected or tracked.get(path, (None,))[0] == "160000"
    )
    for path in paths:
        if path in skipped or ".git" in Path(path).parts:
            continue
        try:
            mode, contents = _read_entry(source, path)
        except FileNotFoundError:
            if path in tracked:
                _git(directory, "update-index", "--force-remove", "--", path)
            continue
        except OSError as error:
            raise WorkspaceError(
                f"Cannot snapshot {path} without following a directory symlink: {error}"
            ) from error
        oid = _text(directory, "hash-object", "-w", "--stdin", data=contents)
        if tracked.get(path) != (mode, oid):
            _git(directory, "update-index", "--add", "--cacheinfo", mode, oid, path)
    tree = _text(directory, "write-tree")
    if tree == _text(directory, "rev-parse", base + "^{tree}"):
        return base, sorted(protected), skipped
    commit = _text(
        directory,
        "commit-tree",
        tree,
        "-p",
        base,
        data=b"Snapshot authorized working files for Pi\n",
    )
    return commit, sorted(protected), skipped


def _allocate(session_root, record_root, branch, base):
    session_root = Path(session_root).absolute()
    record_root = (
        Path(record_root).absolute()
        if record_root
        else session_root.with_name(session_root.name + ".record")
    )
    if record_root == session_root or session_root in record_root.parents:
        raise WorkspaceError(
            "Trusted records must be outside the writable session root"
        )
    if not OID.fullmatch(base):
        raise WorkspaceError("base must be a full commit object ID")
    session_root.mkdir(mode=0o700)
    record_root.mkdir(mode=0o700)
    bare = session_root / ".bare"
    _init_bare(bare, base)
    _git(bare, "check-ref-format", "--branch", branch)
    return session_root, record_root, bare


def _copy_history(bare, objects, base, record_root):
    with tempfile.TemporaryFile(dir=record_root) as pack:
        _git(
            bare,
            "pack-objects",
            "--stdout",
            "--revs",
            data=(base + "\n").encode(),
            extra={"GIT_ALTERNATE_OBJECT_DIRECTORIES": str(objects)},
            output=pack,
        )
        pack.seek(0)
        result = subprocess.run(
            [GIT, "--git-dir=" + str(bare), "index-pack", "--stdin", "--strict"],
            stdin=pack,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=_environment(),
            timeout=120,
        )
        if result.returncode:
            raise WorkspaceError(
                "Source object verification failed: "
                + result.stderr.decode(errors="replace")[:1000]
            )
    _git(bare, "cat-file", "-e", base + "^{commit}")


def _finish_workspace(
    session_root, record_root, bare, branch, source, base, snapshot, protected, skipped
):
    _git(bare, "update-ref", "refs/heads/" + branch, snapshot)
    _git(bare, "symbolic-ref", "HEAD", "refs/heads/" + branch)
    _git(bare, "config", "core.logAllRefUpdates", "true")
    _git(bare, "read-tree", snapshot)
    for name in set(_attributes(bare, protected).values()):
        if name.startswith("git-crypt"):
            _git(bare, "config", f"filter.{name}.required", "true")
            _git(bare, "config", f"filter.{name}.clean", "false")
            _git(bare, "config", f"filter.{name}.smudge", "false")
    _git(bare, "config", "filter.git-crypt.clean", "git-crypt clean")
    _git(bare, "config", "filter.git-crypt.smudge", "git-crypt smudge")
    _git(bare, "config", "filter.git-crypt.required", "true")
    base_bundle = record_root / "base.bundle"
    _git(bare, "bundle", "create", str(base_bundle), "HEAD")
    workspace = session_root / "worktree"
    _git(bare, "worktree", "add", "--no-checkout", str(workspace), branch)
    git_dir = bare / "worktrees" / "worktree"
    _git(git_dir, "config", "extensions.worktreeConfig", "true")
    _git(git_dir, "config", "--worktree", "core.bare", "false")
    _git(git_dir, "config", "--worktree", "core.worktree", str(workspace))
    _git(git_dir, "config", "--worktree", "core.sparseCheckout", "true")
    _git(git_dir, "config", "--worktree", "core.sparseCheckoutCone", "false")
    sparse = git_dir / "info" / "sparse-checkout"
    sparse.parent.mkdir(parents=True, exist_ok=True)
    # Escape gitignore metacharacters so protected filenames cannot add include rules.
    lines = ["/*"] + [
        "!/" + re.sub(r"([\\*?\[\] !#])", r"\\\1", path) for path in protected
    ]
    if any("\n" in path or "\r" in path for path in protected):
        raise WorkspaceError(
            "Protected filenames containing newlines cannot be represented in sparse checkout"
        )
    sparse.write_text("\n".join(lines) + "\n")
    _git(git_dir, "--work-tree=" + str(workspace), "checkout", "--quiet", "HEAD")
    info = session_root.stat()
    manifest = {
        "session_root": str(session_root),
        "record_root": str(record_root),
        "workspace": str(workspace),
        "git_dir": str(git_dir),
        "common_dir": str(bare),
        "branch": branch,
        "source": str(source),
        "source_base": base,
        "snapshot_commit": snapshot,
        "base_bundle": str(base_bundle),
        "protected_paths": protected,
        "omitted_working_paths": skipped,
        "root_identity": [info.st_dev, info.st_ino],
    }
    (record_root / "workspace.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def create(source, session_root, branch, base=None, *, record_root=None):
    """Snapshot human-authorized working files; never use this on a running agent's directory."""
    source = Path(source).resolve(strict=True)
    own, common, objects = _source_metadata(source)
    base = base or _source_head(own, common)
    session_root, record_root, bare = _allocate(session_root, record_root, branch, base)
    _copy_history(bare, objects, base, record_root)
    snapshot, protected, skipped = _snapshot(bare, source, base, own, common)
    return _finish_workspace(
        session_root,
        record_root,
        bare,
        branch,
        source,
        base,
        snapshot,
        protected,
        skipped,
    )


def create_from_snapshot(manifest, session_root, branch, *, record_root=None):
    """Start a child at a recorded immutable snapshot, without reading its parent's mutable files."""
    base = manifest["snapshot_commit"]
    session_root, record_root, bare = _allocate(session_root, record_root, branch, base)
    _fetch_bundle(bare, manifest["base_bundle"], "refs/base")
    if _text(bare, "rev-parse", "refs/base") != base:
        raise WorkspaceError("Recorded snapshot bundle does not match its manifest")
    return _finish_workspace(
        session_root,
        record_root,
        bare,
        branch,
        manifest["source"],
        base,
        base,
        manifest["protected_paths"],
        [],
    )


def create_from_admitted(admitted, session_root, branch, *, record_root=None):
    """Start a child from broker-owned, admitted Git objects."""
    base = admitted["tip"]
    source = Path(admitted["quarantine"]) / "repository.git"
    session_root, record_root, bare = _allocate(session_root, record_root, branch, base)
    _copy_history(bare, source / "objects", base, record_root)
    _git(bare, "read-tree", base)
    protected = sorted(_protected(bare, list(_tracked(bare))))
    return _finish_workspace(
        session_root, record_root, bare, branch, source, base, base, protected, []
    )


def _fetch_bundle(bare, bundle, ref):
    _git(bare, "bundle", "verify", str(bundle))
    _git(
        bare,
        "-c",
        "fetch.fsckObjects=true",
        "-c",
        "transfer.fsckObjects=true",
        "fetch",
        "--no-write-fetch-head",
        "--no-tags",
        "--no-auto-maintenance",
        str(bundle),
        "HEAD:" + ref,
    )


def _copy_bundle(manifest, source, destination, limit):
    root = Path(manifest["session_root"])
    try:
        relative = Path(source).absolute().relative_to(root)
        parent, name = _open_parent(root, relative)
    except (OSError, ValueError) as error:
        raise WorkspaceError(
            "Bundle must be inside its registered workspace, without directory symlinks"
        ) from error
    try:
        info = os.stat(root, follow_symlinks=False)
        if [info.st_dev, info.st_ino] != manifest["root_identity"]:
            raise WorkspaceError("Session root was replaced")
        descriptor = os.open(
            name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent
        )
        with (
            os.fdopen(descriptor, "rb") as incoming,
            open(destination, "xb") as outgoing,
        ):
            before = os.fstat(incoming.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
                raise WorkspaceError(
                    f"Bundle must be a regular file of at most {limit} bytes"
                )
            copied = 0
            while block := incoming.read(min(1024 * 1024, limit + 1 - copied)):
                copied += len(block)
                if copied > limit:
                    raise WorkspaceError("Bundle exceeds its size limit")
                outgoing.write(block)
            if copied != before.st_size or _stamp(before) != _stamp(
                os.fstat(incoming.fileno())
            ):
                raise WorkspaceError("Bundle changed during handoff; export it again")
    except OSError as error:
        raise WorkspaceError(f"Bundle handoff refused: {error}") from error
    finally:
        os.close(parent)


def admit_bundle(
    manifest,
    bundle_path,
    quarantine_root,
    expected_tip,
    request_id,
    *,
    max_bytes=MAX_BUNDLE_BYTES,
    max_commits=MAX_COMMITS,
):
    """Admit data into trusted storage; target fetch/merge must run inside the target sandbox."""
    if not OID.fullmatch(expected_tip) or not re.fullmatch(
        r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}", request_id
    ):
        raise WorkspaceError("Invalid proposal object ID or request ID")
    quarantine = Path(quarantine_root).absolute()
    root = Path(manifest["session_root"])
    if quarantine == root or root in quarantine.parents:
        raise WorkspaceError("Quarantine must be outside worker-writable storage")
    quarantine.mkdir(mode=0o700)
    sealed = quarantine / "proposal.bundle"
    _copy_bundle(manifest, bundle_path, sealed, max_bytes)
    bare = quarantine / "repository.git"
    base = manifest["snapshot_commit"]
    _init_bare(bare, base)
    for bundle, ref in (
        (manifest["base_bundle"], "refs/base"),
        (sealed, "refs/review/" + request_id),
    ):
        if bundle == sealed and _text(
            bare, "bundle", "list-heads", str(bundle)
        ).splitlines() != [expected_tip + " HEAD"]:
            raise WorkspaceError(
                "Proposal must advertise only HEAD at the expected commit"
            )
        _fetch_bundle(bare, bundle, ref)
    if _text(bare, "rev-parse", "refs/base") != base:
        raise WorkspaceError("Recorded base bundle does not match the session's base")
    if _git(
        bare, "merge-base", "--is-ancestor", base, expected_tip, check=False
    ).returncode:
        raise WorkspaceError("Proposal does not descend from its assigned base")
    commits = _text(
        bare,
        "rev-list",
        "--max-count=" + str(max_commits + 1),
        base + ".." + expected_tip,
    ).splitlines()
    if not commits or len(commits) > max_commits:
        raise WorkspaceError(
            f"Proposal must introduce between 1 and {max_commits} commits"
        )
    _git(bare, "read-tree", base)
    protected = set(manifest["protected_paths"])
    for commit in commits:
        changed = {
            os.fsdecode(path)
            for path in _git(
                bare,
                "diff",
                "--no-ext-diff",
                "--no-textconv",
                "--no-renames",
                "--name-only",
                "-z",
                base,
                commit,
            ).stdout.split(b"\0")
            if path
        }
        forbidden = protected.intersection(changed) | _protected(bare, sorted(changed))
        forbidden.update(
            path for path in changed if Path(path).name == ".gitattributes"
        )
        if forbidden:
            raise WorkspaceError(
                "Proposal changes protected content or attributes: "
                + ", ".join(sorted(forbidden))
            )
    admitted = {
        "tip": expected_tip,
        "tree": _text(bare, "rev-parse", expected_tip + "^{tree}"),
        "base": base,
        "bundle": str(sealed),
        "quarantine": str(quarantine),
        "request_id": request_id,
        "commits": len(commits),
    }
    (quarantine / "admitted.json").write_text(json.dumps(admitted, indent=2) + "\n")
    return admitted
