import base64
import hmac
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import signal
import subprocess
import sys
import threading

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import Pool, Server, Store, atomic_json, socket_path
import workspace


class BuildService:
    def __init__(self, builder_config, manifest, record_root, builder_module):
        self.config = builder_config
        self.manifest = manifest
        self.root = Path(record_root)
        self.root.mkdir(parents=True, mode=0o700, exist_ok=True)
        self.module = str(builder_module)
        self.store = Store(self.root / "builds.sqlite")
        self.token = secrets.token_hex(32)
        self.socket = socket_path(self.root)
        self.busy = threading.Lock()
        self.lifecycle = threading.RLock()
        self.children = {}
        self.watchers = []
        self.closed = False
        self.client = {
            "socket": self.socket,
            "token": self.token,
            "workspace": manifest["workspace"],
            "base": manifest["snapshot_commit"],
            "protected_paths": manifest["protected_paths"],
        }
        for identifier, state in self.store.states().items():
            if state["state"] in ("admitting", "running"):
                state.update(
                    state="lost",
                    error="Session stopped before recording completion; this build was not replayed",
                )
                self.store.put(identifier, state)
        self.server = Server(self.socket, self.dispatch)
        self.server.daemon_threads = False
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        with self.lifecycle:
            if self.closed:
                return
            self.closed = True
            children = list(self.children.items())
        for identifier, process in children:
            if process.poll() is None:
                self.cancel(identifier)
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        for watcher in self.watchers:
            watcher.join()
        self.store.db.close()
        Path(self.socket).unlink(missing_ok=True)

    def dispatch(self, body):
        if not isinstance(body.get("token"), str) or not hmac.compare_digest(
            body["token"], self.token
        ):
            raise ValueError("Unauthorized build capability")
        identifier = body.get("id", "")
        if not isinstance(identifier, str) or not re.fullmatch(
            r"[0-9a-f]{32}", identifier
        ):
            raise ValueError("Invalid build id")
        op = body.get("op")
        allowed = {
            "start": {"bundle", "tip", "args"},
            "status": {"offset", "stderr_offset"},
            "cancel": set(),
        }
        if (
            not isinstance(op, str)
            or op not in allowed
            or set(body) - allowed[op] - {"id", "token", "op"}
        ):
            raise ValueError("Unknown build request fields")
        if op == "start":
            return self.store.operation(body, lambda: self.start(identifier, body))
        if self.store.get(identifier) is None:
            raise ValueError("Unknown build")
        if op == "cancel":
            return self.cancel(identifier)
        return self.status(
            identifier, body.get("offset", 0), body.get("stderr_offset", 0)
        )

    def start(self, identifier, body):
        args = body.get("args")
        if (
            not isinstance(args, list)
            or not args
            or args[0] not in ("build", "eval")
            or len(args) > 256
            or any(
                not isinstance(value, str) or len(value) > 4096 or "\0" in value
                for value in args
            )
        ):
            raise ValueError("Expected a bounded nix build or eval argument vector")
        if self.closed or not self.busy.acquire(blocking=False):
            raise ValueError("An isolated build is already active for this session")
        record = self.root / identifier
        process = None
        try:
            record.mkdir(mode=0o700)
            self.store.put(identifier, {"state": "admitting", "record": str(record)})
            admitted = workspace.admit_bundle(
                self.manifest,
                Path(body.get("bundle", "")),
                record / "admitted",
                body.get("tip"),
                identifier,
            )
            vm_records = record / "vm"
            vm_records.mkdir(mode=0o700)
            atomic_json(
                record / "request.json",
                {
                    "config": {**self.config, "record_root": str(vm_records)},
                    "pool": str(Path(self.config["record_root"]) / "pool"),
                    "module": self.module,
                    "admitted": admitted,
                    "args": ["nix", *args],
                },
            )
            with self.lifecycle:
                if self.closed or self.store.get(identifier)["state"] == "cancelled":
                    raise ValueError("Build cancelled before execution")
                with (record / "worker.log").open("ab", buffering=0) as log:
                    process = subprocess.Popen(
                        [sys.executable, "-I", __file__, "--worker", str(record)],
                        stdin=subprocess.DEVNULL,
                        stdout=log,
                        stderr=log,
                        start_new_session=True,
                        env={
                            key: value
                            for key, value in os.environ.items()
                            if key in ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL")
                        },
                    )
                self.children[identifier] = process
                self.store.put(
                    identifier,
                    {"state": "running", "record": str(record), "tip": admitted["tip"]},
                )
            watcher = threading.Thread(
                target=self.watch, args=(identifier, process), daemon=True
            )
            self.watchers.append(watcher)
            watcher.start()
            return {"job": identifier, "receipt": "accepted"}
        except Exception as error:
            self.store.put(
                identifier,
                {
                    "state": "failed",
                    "record": str(record),
                    "error": str(error),
                    "returncode": 1,
                },
            )
            raise
        finally:
            if process is None:
                self.busy.release()

    def watch(self, identifier, process):
        code = process.wait()
        state = self.store.get(identifier)
        result = Path(state["record"]) / "result.json"
        if result.exists():
            state.update(json.loads(result.read_text()))
        elif state["state"] != "cancelled":
            state.update(
                state="lost",
                error="Build worker exited without a result; not replayed",
                returncode=code or 1,
            )
        self.busy.release()
        self.store.put(identifier, state)

    def cancel(self, identifier):
        with self.lifecycle:
            state = self.store.get(identifier)
            if state and state["state"] in ("admitting", "running"):
                state.update(state="cancelled", returncode=130)
                self.store.put(identifier, state)
                process = self.children.get(identifier)
                if process and process.poll() is None:
                    process.terminate()
        return {"receipt": "cancelled"}

    def status(self, identifier, offset, stderr_offset):
        if any(
            type(value) is not int or value < 0 for value in (offset, stderr_offset)
        ):
            raise ValueError("Log offsets must be nonnegative integers")
        state = self.store.get(identifier)
        result = Path(state["record"]) / "result.json"
        if state["state"] == "lost" and result.is_file():
            state.update(json.loads(result.read_text()))
            self.store.put(identifier, state)

        def read_log(name, position):
            logs = sorted((Path(state["record"]) / "vm").glob("build-*/" + name))
            if not logs:
                return "", position, False
            with logs[0].open("rb") as stream:
                stream.seek(position)
                block = stream.read(65536)
                return (
                    base64.b64encode(block).decode("ascii"),
                    position + len(block),
                    stream.tell() < os.fstat(stream.fileno()).st_size,
                )

        output, offset, more = read_log("stdout.log", offset)
        stderr, stderr_offset, more_stderr = read_log("stderr.log", stderr_offset)
        return {
            **state,
            "output": output,
            "offset": offset,
            "stderr": stderr,
            "stderr_offset": stderr_offset,
            "encoding": "base64",
            "more": more or more_stderr,
        }


def worker(record):
    request_data = json.loads((record / "request.json").read_text())
    cancelled = False

    def stop(*_):
        nonlocal cancelled
        cancelled = True
        raise RuntimeError("Isolated build cancelled")

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    slot = Pool(request_data["pool"], "build", 1)
    try:
        slot.acquire()
        spec = importlib.util.spec_from_file_location(
            "alamode_native_builder", request_data["module"]
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        result = module.build(
            request_data["config"], request_data["admitted"], request_data["args"]
        )
        outcome = {
            "state": "completed" if result["status"] == "completed" else "failed",
            "returncode": result.get("returncode", 1),
            "builder": result,
        }
    except Exception as error:
        outcome = {
            "state": "cancelled" if cancelled else "failed",
            "returncode": 130 if cancelled else 1,
            "error": str(error),
        }
    finally:
        slot.release()
    atomic_json(record / "result.json", outcome)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--worker":
        worker(Path(sys.argv[2]))
    else:
        raise SystemExit("BuildService is started only by the trusted session launcher")
