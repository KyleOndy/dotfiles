"""Run only inside a fresh, credential-free Darwin builder guest."""

import json
import hashlib
import os
from pathlib import Path
import re
import socket
import subprocess
import sys

import workspace


def materialize(root, manifest, items):
    worktree = Path(manifest["workspace"])
    for item in items:
        target = item["target"]
        if (
            target not in manifest["protected_paths"]
            or ".git-crypt" in Path(target).parts
        ):
            raise RuntimeError(
                "Materialized target is not an authorized protected file"
            )
        contents = (root / item["payload"]).read_bytes()
        if hashlib.sha256(contents).hexdigest() != item["sha256"]:
            raise RuntimeError("Materialized source digest changed during transfer")
        directory = os.open(worktree, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            parts = workspace._parts(target)
            for part in parts[:-1]:
                try:
                    os.mkdir(part, mode=0o700, dir_fd=directory)
                except FileExistsError:
                    pass
                child = os.open(
                    part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory
                )
                os.close(directory)
                directory = child
            descriptor = os.open(
                parts[-1],
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=directory,
            )
            with os.fdopen(descriptor, "wb") as output:
                output.write(contents)
        finally:
            os.close(directory)


def store_builder(executable):
    """Nix expression for a store executable, so the sandbox admits it as an input.

    A profile symlink such as /nix/var/nix/profiles/default/bin/python3 is not
    a derivation input, and the Darwin sandbox refuses to exec it.
    """
    resolved = Path(os.path.realpath(executable))
    parts = resolved.parts
    if parts[:3] != ("/", "nix", "store") or len(parts) < 5:
        raise RuntimeError("Guest Python must resolve into the Nix store")
    if not re.fullmatch(r"[A-Za-z0-9._+/-]+", str(resolved)):
        raise RuntimeError("Guest Python path has unsupported characters")
    package = str(Path(*parts[:4]))
    inside = str(Path(*parts[4:]))
    return '"${builtins.storePath ' + json.dumps(package) + "}/" + inside + '"'


def build_arguments(arguments, worktree, has_materialized_inputs):
    if not has_materialized_inputs or arguments[:2] not in (
        ["nix", "build"],
        ["nix", "eval"],
    ):
        return arguments
    flake = "path:" + str(worktree)
    rewritten = [
        flake + value[1:] if value == "." or value.startswith(".#") else value
        for value in arguments
    ]
    if arguments[1] == "build" and all(
        value
        in (
            "--no-link",
            "--impure",
            "--rebuild",
            "--dry-run",
            "--show-trace",
            "--print-build-logs",
            "-L",
        )
        for value in arguments[2:]
    ):
        rewritten.append(flake)
    return rewritten


def main(root):
    request = json.loads((root / "request.json").read_text())
    if os.getuid() != 0 or sys.platform != "darwin":
        raise RuntimeError("Builder probes require root inside a native Darwin guest")
    os.environ.clear()
    # The guest reaches only its DNS server, so a substituter lookup can
    # only time out; the host materializes every input before the job.
    os.environ.update(
        PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        HOME="/var/root",
        TMPDIR="/private/tmp",
        LC_ALL="C",
        NIX_CONFIG="substitute = false",
    )
    if Path(request["canary"]).exists():
        raise RuntimeError("Host canary is visible inside the VM")
    mounts = subprocess.check_output(["/sbin/mount"], text=True)
    if "virtiofs" in mounts.lower() or "virtio-fs" in mounts.lower():
        raise RuntimeError("Host filesystem share is mounted")
    routes = subprocess.check_output(["/sbin/route", "-n", "get", "default"], text=True)
    gateway = next(
        line.split(":", 1)[1].strip()
        for line in routes.splitlines()
        if "gateway:" in line
    )
    probes = {
        (host, request["probe_port"])
        for host in request["host_addresses"]
        if not host.startswith("127.")
    }
    probes.add((gateway, request["probe_port"]))
    probes.update((("169.254.169.254", 80), ("168.63.129.16", 80)))
    for host, port in sorted(probes):
        try:
            connection = socket.create_connection((host, port), timeout=0.5)
        except OSError:
            continue
        connection.close()
        raise RuntimeError("Guest reached a host or metadata probe")
    services = subprocess.check_output(
        ["/usr/sbin/networksetup", "-listallnetworkservices"], text=True
    ).splitlines()[1:]
    for service in services:
        if service and not service.startswith("*"):
            subprocess.run(
                [
                    "/usr/sbin/networksetup",
                    "-setdnsservers",
                    service,
                    *request["dns_servers"],
                ],
                check=True,
            )
    probe_script = (
        "import os,pathlib,socket\n"
        + "assert not pathlib.Path("
        + repr(request["canary"])
        + ").exists()\n"
        + "for target in "
        + repr(sorted(probes))
        + ":\n"
        + " try:\n  connection=socket.create_connection(target,timeout=0.5)\n"
        + " except OSError:\n  continue\n"
        + " connection.close()\n raise RuntimeError('builder reached host or metadata')\n"
        + "pathlib.Path(os.environ['out']).write_text('native-source-build')\n"
    )
    probe = root / "boundary.nix"
    probe.write_text(
        'derivation { name = "alamode-boundary-probe"; system = builtins.currentSystem; '
        "builder = "
        + store_builder(sys.executable)
        + '; args = [ "-c" '
        + json.dumps(probe_script).replace("${", r"\${")
        + ' ]; __sandboxProfile = "(allow file-read* file-write* network*)"; }\n'
    )
    subprocess.run(
        [
            "nix",
            "build",
            "--impure",
            "--no-link",
            "--file",
            str(probe),
        ],
        check=True,
        stdout=sys.stderr,
    )
    manifest = workspace.create_from_snapshot(
        {
            "snapshot_commit": request["snapshot_commit"],
            "base_bundle": str(root / "source.bundle"),
            "source": "admitted snapshot",
            "protected_paths": request["protected_paths"],
        },
        root / "session",
        "alamode-build",
    )
    os.environ["DOTFILES_WORKTREE"] = manifest["workspace"]
    materialized = request.get("materialized_inputs", [])
    materialize(root, manifest, materialized)
    if materialized:
        os.environ["ALAMODE_BUILD_FLAKE"] = "path:" + manifest["workspace"]
    os.chdir(manifest["workspace"])
    print("alamode native builder boundary probes passed", file=sys.stderr, flush=True)
    return subprocess.run(
        build_arguments(
            request["command_args"], manifest["workspace"], bool(materialized)
        )
    ).returncode


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
