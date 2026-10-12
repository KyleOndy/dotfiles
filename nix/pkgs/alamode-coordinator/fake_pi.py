import json
import os
from pathlib import Path
import sys
import threading
import time

output = threading.Lock()
running = False
aborted = threading.Event()
queued = []
dialog = None
manifest = json.loads(
    Path(sys.argv[sys.argv.index("--managed-manifest") + 1]).read_text()
)
runtime = Path(manifest["workspace"]["session_root"]) / "runtime"
runtime.mkdir(exist_ok=True)
(runtime / "pid").write_text(str(os.getpid()))
(runtime / "environment.json").write_text(json.dumps(dict(os.environ)))
session = Path(sys.argv[sys.argv.index("--session") + 1])
session.parent.mkdir(parents=True, exist_ok=True)


def emit(value):
    with output:
        print(json.dumps(value), flush=True)


def run(message):
    global running
    emit({"type": "agent_start"})
    with session.open("a") as stream:
        stream.write(json.dumps({"role": "user", "text": message}) + "\n")
    if "tool" in message:
        emit(
            {
                "type": "tool_execution_start",
                "toolName": "bash",
                "args": {"command": "ls \x1b]0;pwned\x07 -la\n‮rm"},
            }
        )
    aborted.wait(30.0 if "hold" in message else 1.0 if "slow" in message else 0.04)
    reason = "aborted" if aborted.is_set() else "error" if "fail" in message else "stop"
    emit(
        {
            "type": "message_end",
            "message": {
                "role": "assistant",
                "stopReason": reason,
                "errorMessage": "fixture failure" if reason == "error" else None,
                "content": []
                if "empty" in message
                else [{"type": "text", "text": "reply:" + message}],
            },
        }
    )
    emit({"type": "agent_end"})
    if queued and not aborted.is_set():
        run(queued.pop(0))
    else:
        running = False
        emit({"type": "agent_settled"})


for line in sys.stdin:
    command = json.loads(line)
    kind = command["type"]
    data = {}
    if kind == "extension_ui_response":
        dialog = None
        continue
    if kind == "get_state":
        data = {
            "isStreaming": running,
            "pendingMessageCount": len(queued),
            "sessionFile": str(session),
        }
    elif kind == "clear_queue":
        queued.clear()
    elif kind == "abort":
        aborted.set()
        while running:
            time.sleep(0.005)
    elif kind in ("prompt", "steer", "follow_up"):
        message = command["message"]
        if message == "/question":
            dialog = "fixture-dialog"
            emit(
                {
                    "type": "extension_ui_request",
                    "method": "input",
                    "id": dialog,
                    "title": "Fixture question",
                }
            )
            data = {"disposition": "handled"}
        elif running:
            queued.append(message)
            data = {"disposition": "queued"}
        else:
            running = True
            aborted.clear()
            data = {"disposition": "started"}
            threading.Thread(target=run, args=(message,), daemon=True).start()
    emit(
        {
            "type": "response",
            "id": command.get("id"),
            "command": kind,
            "success": True,
            "data": data,
        }
    )
