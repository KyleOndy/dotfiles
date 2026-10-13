import fcntl
import os
from pathlib import Path
import re
import secrets
import subprocess

from common import Store

SIZES = {"small": 4, "large": 8, "xlarge": 16}


class Forge:
    def __init__(self, config):
        self.config = config
        self.root = Path(config["pool"])
        self.root.mkdir(parents=True, mode=0o700, exist_ok=True)
        self.store = Store(self.root / "forge.sqlite")

    def command(self, args, lease=None):
        env = {
            key: os.environ[key]
            for key in ("PATH", "HOME", "TMPDIR")
            if key in os.environ
        }
        if lease:
            env.update(
                FORGE_INSTANCE=str(lease["instance"]), FORGE_LEASE_LABEL=lease["label"]
            )
            small = Path.home() / ".config/forge/forge-small.yaml"
            if lease["size"] == "small" and small.is_file():
                env["FORGE_CONFIG"] = str(small)
        result = subprocess.run(
            [self.config.get("forge_bin", "forge"), *args],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=900,
        )
        if result.returncode:
            raise ValueError((result.stderr or result.stdout)[-4000:])
        return result.stdout.strip()

    def claim(self, size, owner):
        policy = self.config["policy"]
        if not self.config.get("with_forge") or not policy.get("forge"):
            raise ValueError("Forge is outside this session's authorized capabilities")
        if size not in SIZES or size not in policy.get("forge_sizes", list(SIZES)):
            raise ValueError("Forge size is outside this session's authorized sizes")
        with (self.root / "forge-budget.lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            # A lease without an instance never reached `forge init`, so no VM
            # holds its memory.
            used = sum(
                value["memory"]
                for value in self.store.states().values()
                if "instance" in value and value["state"] != "released"
            )
            if used + SIZES[size] > self.config.get("memory_budget_gib", 32):
                raise ValueError("Forge memory budget exhausted")
            lease = {
                "label": "alamode-" + secrets.token_hex(20),
                "size": size,
                "memory": SIZES[size],
                "state": "claiming",
                "owner": owner,
            }
            self.store.put(lease["label"], lease)
            try:
                instance = self.command(["claim", lease["label"]])
                if not re.fullmatch(r"[1-9][0-9]?", instance) or int(instance) > 15:
                    raise ValueError("Forge claim returned an invalid instance")
                lease.update(instance=int(instance), state="claimed")
                self.store.put(lease["label"], lease)
                self.command(["init", "--size", size], lease)
                lease["state"] = "stopped"
                self.store.put(lease["label"], lease)
                return lease
            except Exception as error:
                lease.update(state="uncertain", error=str(error))
                self.store.put(lease["label"], lease)
                return lease

    def boot(self, lease):
        current = self.store.get(lease["label"])
        if (
            not current
            or current.get("instance") != lease.get("instance")
            or current["state"] == "released"
        ):
            raise ValueError("Forge lease is no longer owned by this agent")
        if current["state"] == "uncertain":
            raise ValueError(
                "Forge setup for this agent failed, so its VM does not boot. "
                "Tear the agent down to release the lease."
            )
        self.command(["start"], current)
        current["state"] = "running"
        self.store.put(current["label"], current)
        return current

    def resource(self, lease, runtime):
        home = Path.home()
        instance = lease["instance"]
        lima = home / ".lima"
        socket = lima / f"forge-{instance}" / "sock/docker.sock"
        config = home / ".local/state/forge" / str(instance) / "forge.yaml"
        kubeconfig = (
            Path(runtime)
            / "home/.local/state/forge"
            / str(instance)
            / "kubeconfig.yaml"
        )
        start = 6440 + instance * 16
        return {
            "socket": str(socket),
            "read_paths": [str(config)],
            "local_ports": list(range(start, start + 16)) + [6420, 6421, 6422],
            "env": {
                "FORGE_INSTANCE": str(instance),
                "LIMA_HOME": str(lima),
                "FORGE_CONFIG": str(config),
                "KUBECONFIG": str(kubeconfig),
                "DOCKER_HOST": "unix://" + str(socket),
            },
            "ownership_ref": lease["label"],
        }

    def release(self, lease):
        with (self.root / "forge-budget.lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            current = self.store.get(lease["label"])
            if (
                not current
                or not lease.get("instance")
                or current.get("instance") != lease["instance"]
            ):
                raise ValueError("Forge lease is no longer owned by this agent")
            if current["state"] == "released":
                return current
            self.command(["release", current["label"]], current)
            current["state"] = "released"
            self.store.put(current["label"], current)
            return current
