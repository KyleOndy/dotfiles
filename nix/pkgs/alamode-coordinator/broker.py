import argparse
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import threading
import time
import uuid

from common import (
    Store,
    Server,
    atomic_json,
    lock_file,
    request,
    socket_path,
    wait_socket,
)

NAME = re.compile(r"[a-z][a-z0-9_-]{0,47}\Z")
THINKING = {"off", "minimal", "low", "medium", "high", "xhigh", "max"}


def read_json(path):
    return json.loads(Path(path).read_text())


def retention_limit(config):
    limit = config.get("max_retained_agents", 4 * config["max_workers"])
    if type(limit) is not int or not 1 <= limit <= 4096:
        raise ValueError("max_retained_agents must be an integer between 1 and 4096")
    return limit


def detached(mode, config, log):
    with open(log, "ab", buffering=0) as output:
        return subprocess.Popen(
            [sys.executable, __file__, mode, str(config)],
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=output,
            start_new_session=True,
        )


class Broker:
    def __init__(self, config):
        self.config = config
        self.max_retained_agents = retention_limit(config)
        self.directory = Path(config["directory"])
        self.store = Store(self.directory / "broker.sqlite")

    def agent(self, name):
        value = self.store.get(name)
        if value is None:
            raise ValueError(f"Unknown agent: {name}")
        return value

    def worker(self, agent, body, timeout=30):
        return request(agent["socket"], agent["token"], body, timeout=timeout)

    def reconcile(self):
        for name, agent in self.store.states().items():
            if (
                agent["state"] in ("creating", "starting")
                and not Path(agent["config"]).exists()
            ):
                agent.update(
                    state="failed",
                    error="Coordinator stopped during setup. Existing work is preserved; use a new agent name.",
                )
                self.store.put(name, agent)

    def status(self, agent, summary=False):
        public = {
            key: value
            for key, value in agent.items()
            if key
            not in ("token", "child_token", "socket", "config", "manifest", "proposal")
        }
        if agent.get("proposal"):
            public["proposal"] = {
                key: agent["proposal"][key] for key in ("tip", "base", "commits")
            }
        try:
            public.update(self.worker(agent, {"op": "status"}, timeout=1))
        except (OSError, ValueError):
            worker_state = Path(agent["config"]).parent / "agent.sqlite"
            if worker_state.exists():
                storage = Store(worker_state)
                try:
                    stored = storage.get("status", {})
                finally:
                    storage.db.close()
                if stored.get("state") == "closed":
                    public.update(stored)
            if public["state"] not in ("creating", "failed", "closed"):
                public["state"] = "lost"
                public["error"] = (
                    "Supervisor unavailable; resume reconnects or recovers without replaying work"
                )
        if summary:
            for key in ("outcome", "report", "question"):
                if public.get(key):
                    public[key] = {
                        **public[key],
                        "text": public[key].get("text", "")[:2000],
                    }
        if public.get("forge"):
            public["forge"] = {
                key: value for key, value in public["forge"].items() if key != "label"
            }
        return public

    def authenticate(self, token):
        if not isinstance(token, str):
            raise ValueError("Unauthorized")
        if hmac.compare_digest(token, self.config["token"]):
            return None
        for agent in self.store.states().values():
            if hmac.compare_digest(token, agent["child_token"]):
                return agent
        raise ValueError("Unauthorized")

    def dispatch(self, body):
        child = self.authenticate(body.get("token"))
        op = body.get("op")
        fields = {
            "spawn": {
                "agent",
                "task",
                "model",
                "thinking",
                "size",
                "base",
                "bundle",
                "tip",
                "read_only",
                "include_commits",
            },
            "status": {"agent"},
            "result": {"agent"},
            "events": {"agent", "after"},
            "send": {"agent", "message", "mode"},
            "answer": {"agent", "dialog", "value", "cancelled"},
            "interrupt": {"agent"},
            "resume": {"agent"},
            "close": {"agent"},
            "teardown": {"agent", "remove"},
            "report": {"message"},
            "question": {"message"},
            "forge_boot": {"agent"},
            "offer": {"bundle", "tip"},
            "admit": {"agent"},
            "shutdown": set(),
        }
        if not isinstance(op, str) or op not in fields:
            raise ValueError("Unknown coordinator operation")
        if set(body) - fields[op] - {"op", "id", "token"}:
            raise ValueError(
                "Unknown operation fields; grants and commands come only from the trusted launch manifest"
            )
        if child:
            if op == "status":
                return self.status(child)
            if op in ("report", "question"):
                if not isinstance(body.get("id"), str) or not body["id"]:
                    raise ValueError("A child message requires an operation id")
                return self.store.operation(
                    {**body, "id": child["agent"] + ":" + str(body.get("id", ""))},
                    lambda: self.child_message(child, body),
                )
            if op == "forge_boot":
                return self.store.operation(
                    {**body, "id": child["agent"] + ":" + str(body.get("id", ""))},
                    lambda: self.forge_action(child, "boot"),
                )
            if op == "offer":
                return self.store.operation(
                    {**body, "id": child["agent"] + ":" + str(body.get("id", ""))},
                    lambda: self.offer(child, body),
                )
            raise ValueError(
                "Child capability permits only own status, report and question"
            )
        if op == "status":
            if body.get("agent"):
                return self.status(self.agent(body["agent"]))
            return {
                "coordinator": self.config["coordinator"],
                "agents": [
                    self.status(agent, summary=True)
                    for _, agent in sorted(self.store.states().items())
                ],
                "limits": {
                    "active": self.config["max_agents"],
                    "workers": self.config["max_workers"],
                    "retained_agents": self.max_retained_agents,
                },
                "forge": bool(
                    self.config.get("with_forge") and self.config["policy"].get("forge")
                ),
            }
        if op == "shutdown":
            # serve() removes the socket and pidfile on its way out, and the
            # lock goes with the process. Supervisors are detached, so agents
            # keep running and a later attach finds them.
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return {"coordinator": self.config["coordinator"], "state": "stopping"}
        if op == "spawn":
            return self.store.operation(body, lambda: self.spawn(body))
        agent = self.agent(body.get("agent"))
        if op == "admit":
            return self.store.operation(body, lambda: self.admit(agent))
        if op == "events":
            return self.worker(agent, {"op": "events", "after": body.get("after", 0)})
        if op == "result":
            state = self.status(agent)
            return {
                "state": state["state"],
                "outcome": state.get("outcome"),
                "report": state.get("report"),
                "question": state.get("question"),
                "verification": state.get("verification"),
            }
        if op == "resume":
            self.withhold_dead_forge(agent)
            self.ensure_supervisor(agent)
        if op in ("send", "interrupt", "answer", "resume", "close"):
            result = self.worker(
                agent,
                {
                    key: value
                    for key, value in body.items()
                    if key not in ("token", "agent")
                },
            )
            if op == "send" and result.get("receipt") == "accepted":
                with self.store.lock:
                    current = self.agent(agent["agent"])
                    current.pop("question", None)
                    self.store.put(agent["agent"], current)
            return result
        if op == "teardown":
            if body.get("remove"):
                raise ValueError(
                    "Workspace removal requires trusted admission and explicit human cleanup; work is preserved"
                )
            return self.store.operation(body, lambda: self.teardown(agent, body["id"]))
        if op == "forge_boot":
            return self.store.operation(body, lambda: self.forge_action(agent, "boot"))
        raise ValueError(f"Unknown coordinator operation: {op}")

    def offer(self, agent, body):
        import workspace

        manifest = read_json(agent["manifest"])["workspace"]
        directory = Path(agent["config"]).parent / ("proposal-" + uuid.uuid4().hex)
        admitted = workspace.admit_bundle(
            manifest,
            Path(body.get("bundle", "")),
            directory,
            body.get("tip"),
            uuid.uuid4().hex,
        )
        with self.store.lock:
            current = self.agent(agent["agent"])
            current["proposal"] = admitted
            self.store.put(agent["agent"], current)
        return {key: admitted[key] for key in ("tip", "base", "commits")}

    def admit(self, agent):
        from session import safe_write

        if not agent.get("proposal"):
            raise ValueError("Ask the child to export_commits before integration")
        parent = self.config["manifest"]["workspace"]
        root = Path(parent["session_root"])
        info = root.stat(follow_symlinks=False)
        if [info.st_dev, info.st_ino] != parent["root_identity"]:
            raise ValueError("Coordinator workspace root was replaced")
        proposal = agent["proposal"]
        relative = "runtime/inbox/" + uuid.uuid4().hex + "/proposal.bundle"
        safe_write(root, relative, Path(proposal["bundle"]).read_bytes())
        return {
            "bundle": str(root / relative),
            **{key: proposal[key] for key in ("tip", "base", "commits")},
        }

    def forge_action(self, agent, action):
        if not agent.get("forge"):
            raise ValueError("Agent has no Forge resource")
        from forge import Forge

        try:
            lease = getattr(Forge(self.config), action)(agent["forge"])
            with self.store.lock:
                current = self.agent(agent["agent"])
                current["forge"] = lease
                self.store.put(agent["agent"], current)
            return {key: value for key, value in lease.items() if key != "label"}
        except Exception as error:
            with self.store.lock:
                current = self.agent(agent["agent"])
                current["forge"]["error"] = str(error)
                self.store.put(agent["agent"], current)
            raise

    def teardown(self, agent, identifier):
        state = self.status(agent)
        if state["state"] != "closed" and Path(agent["config"]).exists():
            try:
                closed = self.worker(
                    agent, {"op": "close", "id": identifier + ":close"}
                )
            except OSError:
                # A supervisor that has exited closed the agent's stdin with
                # it, and pi shuts down when its stdin closes (pi's rpc.md).
                ownership = lock_file(Path(agent["config"]).parent / "supervisor.lock")
                if ownership is None:
                    raise ValueError(
                        "Supervisor still owns this worker but is unreachable; "
                        "nothing was released"
                    )
                ownership.close()
            else:
                if closed.get("receipt") in ("failed", "uncertain"):
                    return closed
        if agent.get("forge"):
            self.forge_action(agent, "release")
        return self.status(self.agent(agent["agent"]))

    def child_message(self, agent, body):
        message = body.get("message")
        if not isinstance(message, str) or not 1 <= len(message) <= 500000:
            raise ValueError("Message must contain 1-500000 characters")
        with self.store.lock:
            current = self.agent(agent["agent"])
            current[body["op"]] = {"text": message, "time": time.time()}
            self.store.put(agent["agent"], current)
        return {"receipt": "recorded"}

    # The launcher grants whatever socket and FORGE_INSTANCE the manifest
    # names, and a released number can belong to another lease's VM.
    def withhold_dead_forge(self, agent):
        if not agent.get("manifest"):
            return
        manifest = read_json(agent["manifest"])
        resource = manifest.get("resources", {}).get("forge")
        if not resource:
            return
        from forge import Forge

        if not Forge(self.config).live(resource):
            del manifest["resources"]["forge"]
            atomic_json(agent["manifest"], manifest)

    def ensure_supervisor(self, agent):
        try:
            return self.worker(agent, {"op": "status"}, timeout=1)
        except (OSError, ValueError):
            pass
        directory = Path(agent["config"]).parent
        ownership = lock_file(directory / "supervisor.lock")
        if ownership is None:
            raise ValueError(
                "Supervisor still owns this worker but is unreachable; no duplicate worker was started"
            )
        ownership.close()
        process = detached("--supervise", agent["config"], directory / "supervisor.log")
        return wait_socket(agent["socket"], agent["token"], process)

    def spawn(self, body):
        name = body.get("agent")
        if not isinstance(name, str) or not NAME.fullmatch(name):
            raise ValueError("Agent name must match [a-z][a-z0-9_-]{0,47}")
        task = body.get("task")
        if not isinstance(task, str) or not task.strip() or len(task) > 1000000:
            raise ValueError("Task must contain 1-1000000 characters")
        model = body.get("model") or self.config["manifest"].get("seats", {}).get(
            "ALAMODE_DELEGATE_MODEL"
        )
        policy = self.config["policy"]
        if body.get("size") and not (
            self.config.get("with_forge") and policy.get("forge")
        ):
            raise ValueError("Forge is outside this session's authorized capabilities")
        thinking = body.get("thinking")
        if (
            isinstance(model, str)
            and ":" in model
            and model.rsplit(":", 1)[1] in THINKING
        ):
            model, default_thinking = model.rsplit(":", 1)
            thinking = thinking or default_thinking
        if model is not None and model not in policy.get("allowed_models", []):
            raise ValueError("Model is outside this session's authorized model list")
        if thinking is not None and thinking not in THINKING:
            raise ValueError("Invalid thinking level")
        if body.get("base"):
            raise ValueError(
                "Select a base through an admitted bundle; raw host Git revisions are not accepted"
            )
        with self.store.lock:
            if self.store.get(name):
                raise ValueError(
                    "Agent name already exists; resume it or use a new name"
                )
            if len(self.store.states()) >= self.max_retained_agents:
                raise ValueError(
                    f"Coordinator retention limit ({self.max_retained_agents}) reached. "
                    "Inspect and archive preserved work before starting a new coordinator, "
                    "or resume an existing agent. No work was deleted."
                )
            directory = self.directory / "agents" / name
            directory.mkdir(mode=0o700, parents=True)
            agent = {
                "agent": name,
                "state": "creating",
                "token": secrets.token_hex(32),
                "child_token": secrets.token_hex(32),
                "socket": socket_path(directory),
                "config": str(directory / "supervisor.json"),
                "created": time.time(),
            }
            self.store.put(name, agent)
        try:
            import workspace

            parent = self.config["manifest"]["workspace"]
            destination = Path(
                policy.get("session_root", str(Path(parent["session_root"]).parent))
            ) / str(uuid.uuid4())
            record = Path(parent["record_root"]).parent / destination.name
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            branch = f"agent/{name}"
            if body.get("bundle"):
                admitted = workspace.admit_bundle(
                    parent,
                    Path(body["bundle"]),
                    directory / "quarantine",
                    body.get("tip"),
                    body["id"],
                )
                metadata = workspace.create_from_admitted(
                    admitted, destination, branch, record_root=record
                )
            else:
                metadata = workspace.create_from_snapshot(
                    parent, destination, branch, record_root=record
                )
            manifest = {
                "version": 1,
                "id": destination.name,
                "workspace": metadata,
                "policy": policy,
                **{
                    key: self.config["manifest"][key]
                    for key in ("seats", "configuration", "launcher", "builder")
                    if key in self.config["manifest"]
                },
                "coordinator": {
                    "socket": self.config["socket"],
                    "token": agent["child_token"],
                    "role": "child",
                    "id": self.config["coordinator"],
                    "agent": name,
                },
                "runtime": {
                    "session_file": str(
                        destination / "runtime" / "sessions" / "main.jsonl"
                    )
                },
            }
            if body.get("size"):
                from forge import Forge

                adapter = Forge(self.config)
                agent["forge"] = adapter.claim(body["size"], str(directory))
                self.store.put(name, agent)
                if agent["forge"]["state"] != "stopped":
                    raise ValueError(
                        agent["forge"].get("error", "Forge resource needs recovery")
                    )
                manifest["resources"] = {
                    "forge": adapter.resource(agent["forge"], destination / "runtime")
                }
            manifest_path = record / "manifest.json"
            atomic_json(manifest_path, manifest)
            command = [
                self.config["launcher"],
                "--managed-manifest",
                str(manifest_path),
                "--",
                "--mode",
                "rpc",
                "--session",
                manifest["runtime"]["session_file"],
            ]
            if model:
                command.extend(["--model", model])
            if thinking:
                command.extend(["--thinking", thinking])
            if body.get("read_only"):
                command.extend(["--tools", "read,grep,find,ls"])
            config = {
                "directory": str(directory),
                "workspace": metadata["workspace"],
                "socket": agent["socket"],
                "token": agent["token"],
                "command": command,
                "environment": policy.get("child_env", {}),
                "pool": self.config["pool"],
                "max_agents": self.config["max_agents"],
                "max_workers": self.config["max_workers"],
            }
            atomic_json(agent["config"], config)
            agent.update(
                workspace=metadata["workspace"],
                branch=branch,
                base=metadata.get("snapshot_commit"),
                session=destination.name,
                state="starting",
                manifest=str(manifest_path),
            )
            self.store.put(name, agent)
            self.ensure_supervisor(agent)
            resumed = self.worker(agent, {"op": "resume", "id": body["id"] + ":resume"})
            if resumed.get("receipt") == "failed":
                raise ValueError(resumed["error"])
            accepted = self.worker(
                agent, {"op": "send", "id": body["id"] + ":prompt", "message": task}
            )
            return {
                "agent": name,
                "session": destination.name,
                "workspace": metadata["workspace"],
                "base": agent["base"],
                "prompt": accepted,
            }
        except Exception as error:
            agent.update(state="failed", error=str(error))
            self.store.put(name, agent)
            raise


def serve(config):
    ownership = lock_file(Path(config["directory"]) / "broker.lock")
    if ownership is None:
        raise ValueError("Coordinator already running")
    broker = Broker(config)
    broker.reconcile()
    with Server(config["socket"], broker.dispatch) as server:
        broker.server = server
        pidfile = Path(config["directory"]) / "broker.pid"
        pidfile.write_text(str(os.getpid()))
        try:
            server.serve_forever()
        finally:
            pidfile.unlink(missing_ok=True)
            Path(config["socket"]).unlink(missing_ok=True)


def main():
    os.umask(0o077)
    argv = sys.argv[1:]
    # Internal re-entry used by the detached daemon and supervisors.
    if len(argv) >= 2 and argv[0] in ("--serve", "--supervise"):
        if argv[0] == "--serve":
            serve(read_json(argv[1]))
            return
        from supervisor import serve as supervise

        supervise(read_json(argv[1]))
        return
    parser = argparse.ArgumentParser(
        prog="alamode-coordinator",
        description="The durable coordinator daemon behind alamode coord.",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    initialize = commands.add_parser(
        "init", help="start or reattach a coordinator for a launch manifest"
    )
    initialize.add_argument("--coord-dir", required=True)
    initialize.add_argument("--repo", required=True)
    initialize.add_argument("--launcher", required=True)
    initialize.add_argument(
        "--policy", default=os.environ.get("ALAMODE_COORD_POLICY_FILE")
    )
    reader = commands.add_parser(
        "credentials", help="print a coordinator's credentials as JSON"
    )
    reader.add_argument("directory")
    args = parser.parse_args(argv)
    if args.command == "credentials":
        config = read_json(Path(args.directory) / "broker.json")
        print(
            json.dumps(
                {
                    **{key: config[key] for key in ("socket", "token", "coordinator")},
                    "session": config["manifest"].get("id"),
                    "manifest": config.get("manifest_path"),
                }
            )
        )
        return
    directory = Path(args.coord_dir).resolve()
    repo_dir, launcher = args.repo, args.launcher
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    init = lock_file(directory / "init.lock")
    if init is None:
        raise ValueError("Coordinator initialization already running; retry")
    config_file = directory / "broker.json"
    if config_file.exists():
        config = read_json(config_file)
        if config["repo_dir"] != str(Path(repo_dir).resolve()) or config[
            "launcher"
        ] != str(Path(launcher).resolve()):
            raise ValueError("Coordinator belongs to a different workspace or launcher")
    else:
        if not args.policy:
            raise ValueError("A trusted launch manifest is required (--policy)")
        manifest = read_json(args.policy)
        if "workspace" not in manifest or "policy" not in manifest:
            raise ValueError("Launch manifest requires workspace and policy")
        max_workers = int(os.environ.get("ALAMODE_COORD_MAX_WORKERS", "16"))
        config = {
            "directory": str(directory),
            "coordinator": directory.name,
            "repo_dir": str(Path(repo_dir).resolve()),
            "launcher": str(Path(launcher).resolve()),
            "socket": socket_path(directory),
            "token": secrets.token_hex(32),
            "policy": manifest["policy"],
            "manifest": manifest,
            "manifest_path": str(Path(args.policy).resolve()),
            "pool": str(directory.parent / "pool"),
            "max_agents": int(os.environ.get("ALAMODE_COORD_MAX_AGENTS", "8")),
            "max_workers": max_workers,
            "max_retained_agents": int(
                os.environ.get(
                    "ALAMODE_COORD_MAX_RETAINED_AGENTS", str(4 * max_workers)
                )
            ),
            "with_forge": os.environ.get("ALAMODE_COORD_FORGE") == "true",
            "memory_budget_gib": int(os.environ.get("ALAMODE_COORD_MEMORY_GIB", "32")),
        }
        retention_limit(config)
        atomic_json(config_file, config)
    try:
        request(config["socket"], config["token"], {"op": "status"}, timeout=1)
    except (OSError, ValueError):
        ownership = lock_file(directory / "broker.lock")
        if ownership is None:
            raise ValueError(
                "Coordinator holds ownership but is unreachable; refusing duplicate startup"
            )
        ownership.close()
        process = detached("--serve", config_file, directory / "broker.log")
        wait_socket(config["socket"], config["token"], process)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"alamode-coordinator: {error}", file=sys.stderr)
        sys.exit(1)
