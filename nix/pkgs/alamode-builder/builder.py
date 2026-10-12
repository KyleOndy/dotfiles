"""Native Darwin jobs in disposable, host-filtered Tart guests.

Only the trusted broker calls this module. Config, admitted objects and record
storage must be outside every workload's writable and readable grants.
"""

import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import socket
import stat
import subprocess
import tarfile
import threading
import time
import uuid

import workspace


SPECIAL = tuple(
    ipaddress.IPv4Network(value)
    for value in (
        "0.0.0.0/8",
        "10.0.0.0/8",
        "100.64.0.0/10",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.0.0.0/24",
        "192.0.2.0/24",
        "192.88.99.0/24",
        "192.168.0.0/16",
        "198.18.0.0/15",
        "198.51.100.0/24",
        "203.0.113.0/24",
        "224.0.0.0/4",
        "240.0.0.0/4",
        "168.63.129.16/32",
    )
)
MAX_LOG_BYTES = 32 * 1024 * 1024


class BuilderError(RuntimeError):
    pass


class MissingPrerequisite(BuilderError):
    pass


def network_policy(cidrs, dns_servers, local_networks):
    if not cidrs or len(cidrs) > 256:
        raise BuilderError("Declare between 1 and 256 public dependency CIDRs")
    allowed = []
    for value in cidrs:
        try:
            network = ipaddress.IPv4Network(value, strict=True)
        except ValueError as error:
            raise BuilderError(
                "Builder destinations must be canonical IPv4 CIDRs"
            ) from error
        if network.prefixlen == 0 or any(
            network.overlaps(blocked) for blocked in (*SPECIAL, *local_networks)
        ):
            raise BuilderError(
                "Builder CIDRs must exclude special and host-connected networks"
            )
        allowed.append(network)
    if not dns_servers or len(dns_servers) > 3:
        raise BuilderError("Declare 1 to 3 public DNS servers inside the allowed CIDRs")
    for value in dns_servers:
        try:
            address = ipaddress.IPv4Address(value)
        except ValueError as error:
            raise BuilderError("DNS servers must be IPv4 literals") from error
        if not any(address in network for network in allowed):
            raise BuilderError("Each DNS server must be covered by an allowed CIDR")
    return [
        "--net-softnet",
        "--net-softnet-block=0.0.0.0/0,@host",
        "--net-softnet-allow=" + ",".join("out " + str(network) for network in allowed),
    ]


def host_networks():
    output = subprocess.check_output(["/sbin/ifconfig", "-a"], text=True)
    networks = set()
    addresses = set()
    for address, mask in re.findall(r"\binet ([0-9.]+) netmask (0x[0-9a-f]+)", output):
        ip = ipaddress.IPv4Address(address)
        netmask = str(ipaddress.IPv4Address(int(mask, 16)))
        addresses.add(str(ip))
        networks.add(ipaddress.IPv4Network(address + "/" + netmask, strict=False))
    if not addresses:
        raise BuilderError("Cannot discover host network interfaces")
    return networks, addresses


def _sha256(path):
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _verified_file(path, digest):
    path = Path(path)
    if not path.exists():
        raise MissingPrerequisite(
            "Builder input has not been provisioned: " + str(path)
        )
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise BuilderError("Pinned builder input must be an absolute regular file")
    if not re.fullmatch(r"[0-9a-f]{64}", digest) or _sha256(path) != digest:
        raise BuilderError("Pinned builder input digest does not match: " + str(path))
    return path


def preflight(config):
    for key in ("tart_home", "record_root", "guest_python"):
        if not Path(config[key]).is_absolute():
            raise BuilderError("Builder paths must be absolute: " + key)
    tart = _verified_file(config["tart"], config["tart_sha256"])
    softnet = _verified_file(config["softnet"], config["softnet_sha256"])
    mode = softnet.stat()
    if mode.st_uid != 0 or not mode.st_mode & stat.S_ISUID or mode.st_mode & 0o022:
        raise MissingPrerequisite(
            "Softnet must be root-owned, SUID and not group/other writable; provision it explicitly"
        )
    base = config["base_vm"]
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}", base):
        raise BuilderError(
            "Builder base must be a local VM name, never a registry reference"
        )
    image = Path(config["tart_home"]) / "vms" / base
    if set(config["image_sha256"]) != {"config.json", "disk.img", "nvram.bin"}:
        raise BuilderError(
            "Pin config.json, disk.img and nvram.bin of a standalone base image"
        )
    for name, digest in config["image_sha256"].items():
        _verified_file(image / name, digest)
    for key, lower, upper in (
        ("cpu", 2, 16),
        ("memory_mib", 4096, 32768),
        ("timeout_seconds", 30, 14400),
    ):
        if type(config[key]) is not int or not lower <= config[key] <= upper:
            raise BuilderError("Invalid builder resource bound: " + key)
    local, addresses = host_networks()
    policy = network_policy(config["allowed_cidrs"], config["dns_servers"], local)
    return tart, softnet, policy, local, addresses


def run_arguments(vm, policy):
    return [
        "run",
        vm,
        "--no-graphics",
        "--no-clipboard",
        "--no-audio",
        "--no-usb-accessories",
        *policy,
    ]


def command_arguments(args):
    if (
        not isinstance(args, list)
        or not args
        or len(args) > 256
        or any(
            not isinstance(value, str) or "\0" in value or len(value) > 4096
            for value in args
        )
    ):
        raise BuilderError("Guest command must be a bounded array of argument strings")
    if args[0] not in ("nix", "make"):
        raise BuilderError("Builder commands must start with nix or make")
    return args


def _check_free_space(config):
    minimum = config.get("min_free_bytes", 10 * 1024**3)
    if type(minimum) is not int or not 1024**3 <= minimum <= 1024**4:
        raise BuilderError("min_free_bytes must be between 1 GiB and 1 TiB")
    for path in (Path(config["record_root"]), Path(config["tart_home"]) / "vms"):
        if shutil.disk_usage(path).free < minimum:
            raise BuilderError(
                f"Builder storage at {path} has less than {minimum} free bytes; "
                "review retained builds and free space before retrying"
            )


def _admit_storage(config):
    maximum = config.get("max_retained_vms", 8)
    if type(maximum) is not int or not 1 <= maximum <= 64:
        raise BuilderError("max_retained_vms must be an integer between 1 and 64")
    storage = Path(config["tart_home"]) / "vms"
    retained = sum(
        path.is_dir() and re.fullmatch(r"build-[0-9a-f]{32}", path.name) is not None
        for path in storage.iterdir()
    )
    if retained >= maximum:
        raise BuilderError(
            f"Builder retains {retained} VMs at {storage}, limit {maximum}; "
            "review and explicitly remove retained build VMs before retrying"
        )
    _check_free_space(config)


def _payload(admitted, record, request, materialized_inputs=()):
    tip = admitted["tip"]
    if not workspace.OID.fullmatch(tip):
        raise BuilderError("Invalid admitted commit")
    bare = record / "export.git"
    workspace._init_bare(bare, tip)
    workspace._copy_history(
        bare, Path(admitted["quarantine"]) / "repository.git" / "objects", tip, record
    )
    workspace._git(bare, "update-ref", "refs/heads/alamode-build", tip)
    workspace._git(bare, "symbolic-ref", "HEAD", "refs/heads/alamode-build")
    bundle = record / "source.bundle"
    workspace._git(bare, "bundle", "create", str(bundle), "HEAD")
    if bundle.stat().st_size > workspace.MAX_BUNDLE_BYTES:
        raise BuilderError("Native build source bundle exceeds its size limit")
    workspace._git(bare, "read-tree", tip)
    request["snapshot_commit"] = tip
    request["protected_paths"] = sorted(
        workspace._protected(bare, list(workspace._tracked(bare)))
    )
    if len(materialized_inputs) > 32:
        raise BuilderError("At most 32 protected source inputs may be materialized")
    request["materialized_inputs"] = []
    inputs = []
    targets = set()
    for item in materialized_inputs:
        source = Path(item["source"])
        target = item["target"]
        if (
            not source.is_absolute()
            or source != source.resolve()
            or {"git-crypt", ".git-crypt"}.intersection(source.parts)
            or target not in request["protected_paths"]
            or ".git-crypt" in Path(target).parts
            or target in targets
        ):
            raise BuilderError(
                "Materialized sources must be explicit regular protected files, never Git keys"
            )
        mode, contents = workspace._read_entry(Path("/"), str(source)[1:])
        if mode == "120000" or hashlib.sha256(contents).hexdigest() != item["sha256"]:
            raise BuilderError("Materialized source changed or is a symlink")
        targets.add(target)
        name = "materialized-" + str(len(inputs))
        frozen = record / name
        frozen.write_bytes(contents)
        frozen.chmod(0o600)
        inputs.append((frozen, name))
        request["materialized_inputs"].append(
            {"target": target, "payload": name, "sha256": item["sha256"]}
        )
    request_path = record / "request.json"
    request_path.write_text(json.dumps(request))
    archive = record / "input.tar"
    with tarfile.open(archive, "w") as output:
        for source, name in [
            (bundle, "source.bundle"),
            (request_path, "request.json"),
            (Path(workspace.__file__), "workspace.py"),
            (Path(__file__).with_name("guest.py"), "guest.py"),
            *inputs,
        ]:
            output.add(source, arcname=name, recursive=False)
    return archive


def _copy_vm_log(process, path, errors):
    try:
        with open(path, "wb") as output:
            remaining = MAX_LOG_BYTES
            while block := os.read(process.stdout.fileno(), 65536):
                output.write(block[:remaining])
                output.flush()
                remaining -= len(block)
                if remaining < 0:
                    raise BuilderError("Native VM exceeded its output limit")
    except (OSError, BuilderError) as error:
        errors.append(str(error))
        process.terminate()


def _collect(process, stdout, stderr, deadline, networks, vm_errors=(), storage=None):
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, stdout)
    selector.register(process.stderr, selectors.EVENT_READ, stderr)
    written = 0
    try:
        while selector.get_map():
            if storage is not None:
                _check_free_space(storage)
            if vm_errors:
                raise BuilderError(vm_errors[0])
            if time.monotonic() >= deadline:
                raise BuilderError("Native build exceeded its time limit")
            if host_networks()[0] != networks:
                raise BuilderError("Host network configuration changed; build stopped")
            for key, _ in selector.select(timeout=1):
                block = os.read(key.fileobj.fileno(), 65536)
                if not block:
                    selector.unregister(key.fileobj)
                    continue
                written += len(block)
                if written > MAX_LOG_BYTES:
                    raise BuilderError("Native build exceeded its output limit")
                key.data.write(block)
                key.data.flush()
        return process.wait(timeout=10)
    finally:
        selector.close()


def build(config, admitted, command_args=None):
    """Run an admitted snapshot. Outputs stay in its retained guest disk; no host NAR import."""
    storage = Path(config["tart_home"])
    if not storage.is_absolute():
        raise BuilderError("Builder paths must be absolute: tart_home")
    descriptor = os.open(
        storage / ".alamode-builder.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600
    )
    with os.fdopen(descriptor, "r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        _admit_storage(config)
        return _build_locked(config, admitted, command_args)


def _build_locked(config, admitted, command_args):
    args = command_arguments(
        command_args
        if command_args is not None
        else config.get("command_args", ["nix", "build", "--no-link"])
    )
    tart, softnet, policy, networks, addresses = preflight(config)
    record = Path(config["record_root"]) / ("build-" + uuid.uuid4().hex)
    record.mkdir(mode=0o700)
    (record / "bin").mkdir()
    (record / "bin" / "softnet").symlink_to(softnet)
    (record / "home").mkdir()
    vm = record.name
    env = {
        "PATH": str(record / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(record / "home"),
        "TART_HOME": config["tart_home"],
        "TART_NO_AUTO_PRUNE": "1",
        "LC_ALL": "C",
    }

    def tart_command(*arguments, **kwargs):
        return subprocess.run(
            [str(tart), *arguments], env=env, check=True, timeout=180, **kwargs
        )

    for executable, version in ((tart, "2.40.1"), (softnet, "0.24.1")):
        value = subprocess.check_output(
            [str(executable), "--version"], env=env, text=True
        ).strip()
        if not re.search(r"\b" + re.escape(version) + r"\b", value):
            raise BuilderError("Builder executable version is not the reviewed version")
    canary = record / "host-only-canary"
    canary.write_text(uuid.uuid4().hex)
    listener = socket.socket()
    result = {
        "vm": vm,
        "record": str(record),
        "tip": admitted["tip"],
        "status": "starting",
    }
    running = None
    executing = None
    log_thread = None
    vm_errors = []
    try:
        listener.bind(("0.0.0.0", 0))
        listener.listen(128)
        request = {
            "command_args": args,
            "dns_servers": config["dns_servers"],
            "canary": str(canary),
            "host_addresses": sorted(addresses),
            "probe_port": listener.getsockname()[1],
        }
        archive = _payload(
            admitted, record, request, config.get("materialized_inputs", [])
        )
        _check_free_space(config)
        tart_command("clone", config["base_vm"], vm)
        tart_command(
            "set",
            vm,
            "--cpu",
            str(config["cpu"]),
            "--memory",
            str(config["memory_mib"]),
        )
        try:
            running = subprocess.Popen(
                [str(tart), *run_arguments(vm, policy)],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            log_thread = threading.Thread(
                target=_copy_vm_log,
                args=(running, record / "vm.log", vm_errors),
                daemon=True,
            )
            log_thread.start()
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                _check_free_space(config)
                if vm_errors:
                    raise BuilderError(vm_errors[0])
                if running.poll() is not None:
                    raise BuilderError(
                        "Native VM stopped before guest agent became ready"
                    )
                # The guest agent answers before the Nix volume and the
                # default profile resolve. Probing /usr/bin/true admits a
                # guest whose Python is missing, which the agent reports as
                # exit 125 with empty logs once the workload starts.
                try:
                    ready = subprocess.run(
                        [str(tart), "exec", vm, config["guest_python"], "-c", "pass"],
                        env=env,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=10,
                    )
                except subprocess.TimeoutExpired:
                    continue
                if ready.returncode == 0:
                    break
                time.sleep(1)
            else:
                raise BuilderError(
                    "Native guest did not become ready: agent or guest Python unavailable"
                )
            # Softnet creates a host interface during boot. Freeze the resulting
            # interface set before admitting repository-controlled execution.
            networks, _ = host_networks()
            network_policy(config["allowed_cidrs"], config["dns_servers"], networks)
            bootstrap = (
                "import os,sys,tarfile,tempfile; "
                "p=tempfile.mkdtemp(prefix='alamode-build-'); "
                "tarfile.open(fileobj=sys.stdin.buffer,mode='r|').extractall(p,filter='data'); "
                "os.execv('/usr/bin/sudo',['sudo','-n',sys.executable,p+'/guest.py',p])"
            )
            with (
                open(archive, "rb") as incoming,
                open(record / "stdout.log", "wb") as stdout,
                open(record / "stderr.log", "wb") as stderr,
            ):
                executing = subprocess.Popen(
                    [
                        str(tart),
                        "exec",
                        "-i",
                        vm,
                        config["guest_python"],
                        "-c",
                        bootstrap,
                    ],
                    env=env,
                    stdin=incoming,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                code = _collect(
                    executing,
                    stdout,
                    stderr,
                    time.monotonic() + config["timeout_seconds"],
                    networks,
                    vm_errors,
                    config,
                )
                if vm_errors:
                    raise BuilderError(vm_errors[0])
                result.update(
                    status="completed" if code == 0 else "failed", returncode=code
                )
        finally:
            if vm_errors:
                result["vm_log_error"] = vm_errors[0]
    except Exception as error:
        result.update(status="failed", error=str(error))
        raise
    finally:
        listener.close()
        if executing is not None and executing.poll() is None:
            executing.terminate()
        if running is not None:
            try:
                tart_command(
                    "stop",
                    vm,
                    "--timeout",
                    "5",
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE,
                )
            except (OSError, subprocess.SubprocessError) as error:
                result["stop_error"] = str(error)
                running.kill()
            running.wait(timeout=15)
            if log_thread is not None:
                log_thread.join(timeout=5)
            running.stdout.close()
        if vm_errors:
            result.update(status="failed", vm_log_error=vm_errors[0])
        (record / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result
