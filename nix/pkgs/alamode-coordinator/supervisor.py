import hmac
import json
import os
from pathlib import Path
import signal
import subprocess
import threading
import time
import unicodedata
import uuid

from common import LIMIT, OutcomeUnknown, Pool, Server, Store, lock_file
from results import classify_result

# Characters; the coordinator draws it as one row.
ACTIVITY_LIMIT = 120


# The child authors every byte of its tool calls, and the row is drawn into
# the human's terminal, where a control or format character is a command.
def activity(event):
    args = event.get("args")
    args = args if isinstance(args, dict) else {}
    target = next(
        (
            args[key]
            for key in ("path", "pattern", "command", "query")
            if isinstance(args.get(key), str)
        ),
        "",
    )
    tool = event.get("toolName")
    text = f"{tool if isinstance(tool, str) else '?'} {target}"
    text = "".join(
        " " if unicodedata.category(char) in ("Cc", "Cf") else char for char in text
    )
    return " ".join(text.split())[:ACTIVITY_LIMIT]


class Supervisor:
    def __init__(self, config):
        self.config = config
        self.store = Store(Path(config["directory"]) / "agent.sqlite")
        self.mutex = threading.RLock()
        self.commands = threading.Lock()
        self.responses = {}
        self.awaiting = set()
        self.condition = threading.Condition()
        self.active = Pool(config["pool"], "active", config["max_agents"])
        self.workers = Pool(config["pool"], "workers", config["max_workers"])
        self.process = None
        self.run_events = []
        self.aborted = False
        previous = self.store.get("status", {})
        self.state = {
            **previous,
            "state": "lost" if previous else "starting",
            "dialogs": {},
            "activity": None,
        }
        self.save()

    def save(self):
        self.state["updated"] = time.time()
        self.store.put("status", self.state)

    def start(self):
        with self.mutex:
            if self.process and self.process.poll() is None:
                return
            self.workers.acquire()
            env = {
                key: os.environ[key]
                for key in ("PATH", "HOME", "TMPDIR", "LANG", "TERM")
                if key in os.environ
            }
            env.update(self.config.get("environment", {}))
            # The launcher replaces these with the child's scoped credentials.
            env.pop("ALAMODE_COORD_TOKEN", None)
            env.pop("ALAMODE_COORD_SOCKET", None)
            try:
                self.process = subprocess.Popen(
                    self.config["command"],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=open(
                        Path(self.config["directory"]) / "runtime.log",
                        "ab",
                        buffering=0,
                    ),
                    cwd=self.config["workspace"],
                    env=env,
                    start_new_session=True,
                )
            except Exception:
                self.workers.release()
                raise
            self.state.update(
                state="idle", dialogs={}, error=None, closing=False, activity=None
            )
            self.save()
            threading.Thread(
                target=self.read, args=(self.process,), daemon=True
            ).start()

    def write(self, value):
        if not self.process or self.process.poll() is not None:
            raise ValueError(
                "Agent lost; use explicit resume, then send a new instruction"
            )
        wire = (json.dumps(value) + "\n").encode()
        if len(wire) > LIMIT:
            raise ValueError("RPC command exceeds 2 MiB")
        self.process.stdin.write(wire)
        self.process.stdin.flush()

    def rpc(self, kind, *, allow_dialog=False, **fields):
        identifier = str(uuid.uuid4())
        with self.condition:
            self.awaiting.add(identifier)
            try:
                self.write({"id": identifier, "type": kind, **fields})
                deadline = time.monotonic() + 15
                while identifier not in self.responses:
                    # Extension commands can await a dialog before acknowledging prompt.
                    if allow_dialog and self.state["dialogs"]:
                        return {"disposition": "waiting_input"}
                    if not self.process or self.process.poll() is not None:
                        raise OutcomeUnknown(
                            "Agent exited before acknowledging command; it was not replayed"
                        )
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise OutcomeUnknown(
                            "RPC acknowledgement timed out; inspect status before retrying with a new id"
                        )
                    self.condition.wait(min(remaining, 0.2))
                response = self.responses.pop(identifier)
            except OSError as error:
                raise OutcomeUnknown(
                    "Agent connection closed during command delivery; it was not replayed"
                ) from error
            finally:
                self.awaiting.discard(identifier)
        if not response.get("success"):
            raise ValueError(response.get("error", "RPC command rejected"))
        return response.get("data", {})

    def read(self, process):
        try:
            while line := process.stdout.readline(LIMIT + 1):
                if len(line) > LIMIT or not line.endswith(b"\n"):
                    raise ValueError("RPC event exceeds 2 MiB")
                event = json.loads(line)
                if event.get("type") == "response":
                    with self.condition:
                        if event.get("id") in self.awaiting:
                            self.responses[event["id"]] = event
                        self.condition.notify_all()
                    continue
                self.observe(event)
        except Exception as error:
            with self.mutex:
                self.state["error"] = str(error)
            process.terminate()
        finally:
            code = process.wait()
            with self.mutex:
                if self.process is process:
                    self.active.release()
                    self.workers.release()
                    self.state["state"] = (
                        "closed" if self.state.get("closing") else "lost"
                    )
                    self.state["dialogs"] = {}
                    if (
                        self.run_events
                        and self.run_events[-1].get("type") != "agent_settled"
                    ):
                        self.state["outcome"] = classify_result(
                            self.run_events, code, aborted=self.aborted
                        )
                    self.save()
                    self.store.event(
                        {
                            "type": "worker_exit",
                            "code": code,
                            "state": self.state["state"],
                        }
                    )
            with self.condition:
                self.condition.notify_all()

    def observe(self, event):
        kind = event.get("type")
        with self.mutex:
            if kind == "agent_start":
                self.run_events = [event]
                self.state["state"] = "executing"
                self.state["outcome"] = None
                self.state["activity"] = "thinking"
            elif kind == "tool_execution_start":
                self.state["activity"] = activity(event)
                # Status only: a tool call is not an outcome, and one per
                # call would crowd the run's events out of the capped log.
                self.save()
                return
            elif (
                kind == "message_end"
                and event.get("message", {}).get("role") == "assistant"
            ):
                self.run_events = [event]
            elif kind == "agent_end" and not self.run_events:
                self.run_events = [event]
            elif kind == "agent_settled":
                self.run_events.append(event)
                self.state["outcome"] = classify_result(
                    self.run_events, aborted=self.aborted
                )
                self.state["state"] = "idle"
                self.state["activity"] = None
                self.active.release()
                self.state["dialogs"] = {}
            elif kind == "extension_ui_request" and event.get("method") in (
                "select",
                "confirm",
                "input",
                "editor",
            ):
                self.state["dialogs"][event["id"]] = event
                self.state["state"] = "waiting_input"
                self.active.release()
            else:
                return
            self.save()
            self.store.event(event)

    def dispatch(self, body):
        if not isinstance(body.get("token"), str) or not hmac.compare_digest(
            body["token"], self.config["token"]
        ):
            raise ValueError("Unauthorized")
        op = body.get("op")
        if op == "status":
            return self.store.get("status")
        if op == "events":
            return self.store.events(max(0, int(body.get("after", 0))))
        with self.commands:
            return self.store.operation(body, lambda: self.execute(body))

    def execute(self, body):
        op = body.get("op")
        if op == "resume":
            self.start()
            return self.store.get("status")
        if op == "send":
            message = body.get("message")
            if (
                not isinstance(message, str)
                or not message.strip()
                or len(message) > 1000000
            ):
                raise ValueError("Message must contain 1-1000000 characters")
            mode = body.get("mode", "follow_up")
            if mode not in ("steer", "follow_up"):
                raise ValueError("mode must be steer or follow_up")
            with self.mutex:
                if self.state["state"] not in ("idle", "executing", "waiting_input"):
                    raise ValueError(
                        "Agent is not ready; use explicit resume before sending new work"
                    )
                if self.state["dialogs"]:
                    raise ValueError(
                        "Answer or cancel the pending dialog before sending work"
                    )
                self.active.acquire()
                self.aborted = False
                idle = self.state["state"] == "idle"
                self.state["state"] = "executing"
                self.save()
            try:
                result = self.rpc(
                    "prompt" if idle else mode, allow_dialog=True, message=message
                )
            except OutcomeUnknown:
                with self.mutex:
                    self.state["state"] = "uncertain"
                    self.save()
                raise
            except Exception:
                with self.mutex:
                    self.state["state"] = (
                        "idle"
                        if self.process and self.process.poll() is None
                        else "lost"
                    )
                    self.active.release()
                    self.save()
                raise
            if result.get("disposition") == "handled":
                with self.mutex:
                    if not self.state["dialogs"]:
                        self.state["state"] = "idle"
                        self.active.release()
                        self.save()
            return {"receipt": "accepted", "data": result}
        if op == "answer":
            identifier = body.get("dialog")
            with self.mutex:
                dialog = self.state["dialogs"].get(identifier)
                if not dialog:
                    raise ValueError("No pending dialog with this id")
                value = body.get("value")
                method = dialog["method"]
                if not body.get("cancelled"):
                    if method == "confirm" and not isinstance(value, bool):
                        raise ValueError("Confirmation answer must be boolean")
                    if method != "confirm" and not isinstance(value, str):
                        raise ValueError("Dialog answer must be text")
                    if method == "select" and value not in dialog.get("options", []):
                        raise ValueError("Answer is not a dialog option")
                self.active.acquire()
                self.write(
                    {
                        "type": "extension_ui_response",
                        "id": identifier,
                        "cancelled": bool(body.get("cancelled")),
                        **(
                            {"confirmed": value}
                            if method == "confirm"
                            else {"value": value}
                        ),
                    }
                )
                del self.state["dialogs"][identifier]
                self.state["state"] = "executing"
                self.save()
            runtime = self.rpc("get_state")
            with self.mutex:
                if not runtime.get("isStreaming") and not self.state["dialogs"]:
                    self.state["state"] = "idle"
                    self.active.release()
                    self.save()
            return {"receipt": "answered"}
        if op in ("interrupt", "close"):
            with self.mutex:
                interrupted = self.state["state"] in (
                    "executing",
                    "waiting_input",
                    "uncertain",
                )
                self.aborted = interrupted
                self.state["closing"] = op == "close"
                for identifier in self.state["dialogs"]:
                    self.write(
                        {
                            "type": "extension_ui_response",
                            "id": identifier,
                            "cancelled": True,
                        }
                    )
                self.state["dialogs"] = {}
            if self.process and self.process.poll() is None:
                forced = False
                try:
                    self.rpc("clear_queue")
                    self.rpc("abort")
                except (OutcomeUnknown, ValueError):
                    forced = True
                if op == "close" or forced:
                    self.process.stdin.close()
                    try:
                        self.process.wait(timeout=1 if forced else 5)
                    except subprocess.TimeoutExpired:
                        os.killpg(self.process.pid, signal.SIGTERM)
                        try:
                            self.process.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            os.killpg(self.process.pid, signal.SIGKILL)
                            self.process.wait()
            with self.mutex:
                self.active.release()
                alive = self.process and self.process.poll() is None
                self.state["state"] = (
                    "closed" if op == "close" else "idle" if alive else "lost"
                )
                if interrupted:
                    self.state["outcome"] = classify_result(
                        self.run_events, aborted=True
                    )
                self.save()
            if op == "close":
                threading.Thread(target=self.server.shutdown, daemon=True).start()
            return self.store.get("status")
        raise ValueError(f"Unknown agent operation: {op}")


def serve(config):
    ownership = lock_file(Path(config["directory"]) / "supervisor.lock")
    if ownership is None:
        raise ValueError("Supervisor already owns this worker")
    supervisor = Supervisor(config)
    with Server(config["socket"], supervisor.dispatch) as server:
        supervisor.server = server
        pidfile = Path(config["directory"]) / "supervisor.pid"
        pidfile.write_text(str(os.getpid()))
        try:
            server.serve_forever()
        finally:
            pidfile.unlink(missing_ok=True)
            Path(config["socket"]).unlink(missing_ok=True)
