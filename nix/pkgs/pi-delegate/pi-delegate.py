import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

from common import atomic_json, request


def registry():
    root = (
        Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
        / "pi-delegate"
        / "connections"
    )
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    return root


def validate_name(name):
    import re

    if not re.fullmatch(r"[a-z][a-z0-9_-]{0,47}", name):
        raise ValueError("Name must match [a-z][a-z0-9_-]{0,47}")
    return name


def connection(name):
    if os.environ.get("PI_COORD_SOCKET") and os.environ.get("PI_COORD_TOKEN"):
        return {
            "socket": os.environ["PI_COORD_SOCKET"],
            "token": os.environ["PI_COORD_TOKEN"],
        }
    return json.loads((registry() / (validate_name(name) + ".json")).read_text())


def call(credentials, op, **fields):
    result = request(
        credentials["socket"],
        credentials["token"],
        {"id": str(uuid.uuid4()), "op": op, **fields},
    )
    if result.get("receipt") in ("failed", "uncertain"):
        raise ValueError(
            result.get("error")
            or result.get("message", "Operation requires reconciliation")
        )
    return result


def follow(credentials, name, seconds):
    deadline = time.monotonic() + seconds
    while True:
        state = call(credentials, "status", agent=name)
        kind = state["state"]
        if kind in ("idle", "closed", "lost", "failed", "waiting_input") or state.get(
            "question"
        ):
            print(json.dumps(state, indent=2))
            return (
                0
                if kind == "idle"
                and (state.get("outcome") or {}).get("state") == "success"
                else 1
            )
        if time.monotonic() >= deadline:
            print(
                f"Timed out waiting for {name}; the session continues. Use pi-delegate follow {name}.",
                file=sys.stderr,
            )
            return 124
        time.sleep(0.2)


def message(words):
    return sys.stdin.read() if words == ["-"] else " ".join(words)


def main(argv=None):
    os.umask(0o077)
    argv = list(sys.argv[1:] if argv is None else argv)
    wait_seconds = float(os.environ.get("PI_DELEGATE_WAIT_SECONDS", "1800"))
    actions = {
        "send",
        "steer",
        "follow",
        "stop",
        "interrupt",
        "resume",
        "close",
        "status",
        "result",
        "answer",
        "ls",
    }
    if argv and argv[0] in actions:
        op = argv.pop(0)
        if op == "ls":
            if os.environ.get("PI_COORD_SOCKET"):
                print(json.dumps(call(connection("unused"), "status"), indent=2))
            else:
                for file in sorted(registry().glob("*.json")):
                    try:
                        state = call(connection(file.stem), "status", agent=file.stem)
                        print(f"{file.stem}: {state['state']}")
                    except (OSError, ValueError) as error:
                        print(f"{file.stem}: unavailable: {error}")
            return 0
        if not argv:
            raise ValueError(f"{op} requires an agent name")
        name = validate_name(argv.pop(0))
        credentials = connection(name)
        if op == "follow":
            return follow(credentials, name, wait_seconds)
        if op in ("send", "steer"):
            call(
                credentials,
                "send",
                agent=name,
                message=message(argv),
                mode="steer" if op == "steer" else "follow_up",
            )
            return follow(credentials, name, wait_seconds)
        if op == "answer":
            if len(argv) < 2:
                raise ValueError("answer requires a dialog id and a value, or --cancel")
            dialog, value = argv[0], " ".join(argv[1:])
            parsed = {"true": True, "false": False}.get(value, value)
            print(
                json.dumps(
                    call(
                        credentials,
                        "answer",
                        agent=name,
                        dialog=dialog,
                        value=parsed,
                        cancelled=value == "--cancel",
                    ),
                    indent=2,
                )
            )
            return 0
        if argv:
            raise ValueError(f"Unexpected arguments for {op}")
        print(
            json.dumps(
                call(credentials, "interrupt" if op == "stop" else op, agent=name),
                indent=2,
            )
        )
        return 0
    parser = argparse.ArgumentParser(
        description="Run a durable Pi child in an independent Git workspace. All sessions use the coordinator supervisor."
    )
    parser.add_argument("--name")
    parser.add_argument(
        "--edit",
        action="store_true",
        help="Enable mutation tools inside the private workspace",
    )
    parser.add_argument(
        "--grant",
        action="append",
        default=[],
        help="Trusted standalone bootstrap flag, for example --grant=--allow-nix",
    )
    parser.add_argument("--model", default=os.environ.get("PI_DELEGATE_MODEL"))
    parser.add_argument("--thinking")
    parser.add_argument("brief", nargs="+")
    options = parser.parse_args(argv)
    name = validate_name(options.name or "delegate-" + uuid.uuid4().hex[:12])
    if os.environ.get("PI_COORD_SOCKET"):
        if options.grant:
            raise ValueError("An existing coordinator inherits its recorded grants")
        credentials = connection(name)
    else:
        path = registry() / (name + ".json")
        if path.exists():
            raise ValueError(
                "Agent name already exists; resume it or choose another name"
            )
        result = subprocess.run(
            [
                os.environ.get("PI_DELEGATE_LAUNCHER", "pi"),
                "--start-coordinator",
                *options.grant,
            ],
            text=True,
            stdout=subprocess.PIPE,
            check=True,
        )
        credentials = json.loads(result.stdout)
        atomic_json(path, credentials)
    body = {
        "agent": name,
        "task": message(options.brief),
        "read_only": not options.edit,
    }
    if options.model:
        body["model"] = options.model
    if options.thinking:
        body["thinking"] = options.thinking
    result = call(credentials, "spawn", **body)
    print(f"agent: {name}\nworkspace: {result.get('workspace', '')}", file=sys.stderr)
    if result.get("prompt", {}).get("receipt") in ("failed", "uncertain"):
        raise ValueError(
            result["prompt"].get("error", "Initial prompt was not accepted")
        )
    return follow(credentials, name, wait_seconds)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("Stopped waiting; the agent continues running.", file=sys.stderr)
        sys.exit(130)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"pi-delegate: {error}", file=sys.stderr)
        sys.exit(1)
