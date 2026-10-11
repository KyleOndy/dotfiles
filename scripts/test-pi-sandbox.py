#!/usr/bin/env python3
"""Run the Darwin Pi regression checks and retain their evidence."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import selectors
import signal
import subprocess
import tempfile
import time


MAX_LOG_BYTES = 32 * 1024 * 1024
STOP_GRACE_SECONDS = 2
CHECKS = (
    ("session-and-git", "pi-coding-agent"),
    ("providers-and-tools", "pi-e2e"),
    ("coordinator", "pi-broker"),
    ("delegation", "pi-delegate"),
    ("forge-ownership", "forge-vm"),
    ("model-configuration", "pi-seats"),
    ("credential-output-guard", "leak-guard"),
    ("builder-policy", "pi-builder"),
)


def stop(process):
    # A descendant can retain stdout after the command exits. Its process group
    # still belongs to this check and must not survive a timeout or interrupt.
    try:
        os.killpg(process.pid, signal.SIGINT)
    except ProcessLookupError:
        process.wait()
        return
    try:
        process.wait(timeout=STOP_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        pass
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def prerequisite_result(log_path):
    with log_path.open("rb") as stream:
        stream.seek(max(0, log_path.stat().st_size - 65536))
        lines = stream.read().decode(errors="replace").splitlines()
    for index in range(len(lines) - 1, -1, -1):
        if not lines[index].startswith("{"):
            continue
        try:
            evidence = json.loads("\n".join(lines[index:]))
        except ValueError:
            continue
        if isinstance(evidence, dict) and evidence.get("status") in (
            "skip",
            "missing-prerequisite",
        ):
            return evidence
    return None


def run_check(name, command, report, timeout):
    started = time.monotonic()
    log_path = report / (name + ".log")
    result = {"name": name, "command": command, "log": str(log_path), "status": "fail"}
    print(f"RUN  {name}", flush=True)
    with log_path.open("wb") as log:
        process = None
        try:
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                size = 0
                while selector.get_map():
                    remaining = timeout - (time.monotonic() - started)
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired(command, timeout)
                    for key, _ in selector.select(timeout=min(0.5, remaining)):
                        data = os.read(key.fileobj.fileno(), 65536)
                        if not data:
                            selector.unregister(key.fileobj)
                            continue
                        available = MAX_LOG_BYTES - size
                        log.write(data[:available])
                        size += len(data)
                        if size > MAX_LOG_BYTES:
                            result["reason"] = (
                                f"Exceeded {MAX_LOG_BYTES} byte log limit"
                            )
                            break
                    if "reason" in result:
                        break
                if "reason" not in result:
                    result["returncode"] = process.wait(
                        timeout=max(0, timeout - (time.monotonic() - started))
                    )
                    result["status"] = "pass" if result["returncode"] == 0 else "fail"
        except subprocess.TimeoutExpired:
            result.update(status="timeout", reason=f"Exceeded {timeout}s timeout")
        except KeyboardInterrupt:
            result.update(status="interrupted", reason="Interrupted by operator")
        except FileNotFoundError as error:
            result.update(status="missing-prerequisite", reason=str(error))
        except OSError as error:
            result["reason"] = str(error)
        finally:
            if process is not None:
                stop(process)
                process.stdout.close()
    result["seconds"] = round(time.monotonic() - started, 2)
    if result.get("returncode") in (0, 2):
        evidence = prerequisite_result(log_path)
        if evidence:
            result.update(
                status=evidence["status"],
                reason=evidence.get("reason")
                or evidence.get("error")
                or "Check did not run",
            )
    print(
        f"{result['status'].upper()} {name} ({result['seconds']}s): {log_path}",
        flush=True,
    )
    return result


def checks(repository, system, builder_config):
    for name, attribute in CHECKS:
        yield (
            name,
            [
                "nix",
                "build",
                "--impure",
                "--no-link",
                f"{repository}#checks.{system}.{attribute}",
            ],
            None,
        )
    yield (
        "native-containment",
        ["nix", "run", "--impure", f"{repository}#pi-check-native"],
        None,
    )
    builder = [
        "nix",
        "run",
        "--impure",
        f"{repository}#pi-check-builder",
        "--",
        "--config",
        str(builder_config or ""),
    ]
    reason = (
        None
        if builder_config
        else "Pass --builder-config with a provisioned isolated builder"
    )
    yield "native-builder", builder, reason


def write_report(report, result):
    temporary = report / "report.json.tmp"
    temporary.write_text(json.dumps(result, indent=2) + "\n")
    temporary.replace(report / "report.json")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--report", type=Path, help="New directory for report.json and per-check logs"
    )
    parser.add_argument(
        "--builder-config",
        type=Path,
        help="Trusted native builder configuration; never a file from agent-writable state",
    )
    parser.add_argument(
        "--only",
        action="append",
        default=[],
        help="Run named checks; unselected checks remain skipped in the report",
    )
    parser.add_argument(
        "--timeout", type=int, default=1200, help="Seconds allowed per check"
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List registered checks without running them",
    )
    options = parser.parse_args(argv)
    if platform.system() != "Darwin":
        parser.error(
            "This suite requires Darwin (macOS); other platforms are unsupported"
        )
    system = {"arm64": "aarch64-darwin", "x86_64": "x86_64-darwin"}.get(
        platform.machine()
    )
    if system is None:
        parser.error("Unsupported Darwin architecture: " + platform.machine())
    if options.timeout < 1:
        parser.error("--timeout must be positive")
    os.umask(0o077)
    repository = Path(__file__).resolve().parent.parent
    registry = list(checks(repository, system, options.builder_config))
    unknown = set(options.only) - {name for name, _, _ in registry}
    if unknown:
        parser.error("Unknown checks: " + ", ".join(sorted(unknown)))
    if options.list:
        for name, _, missing in registry:
            print(name + (f" ({missing})" if missing else ""))
        return 0
    try:
        if options.report:
            options.report.mkdir(mode=0o700, parents=True, exist_ok=False)
            report = options.report.resolve()
        else:
            report = Path(tempfile.mkdtemp(prefix="pi-sandbox-tests-"))
    except OSError as error:
        parser.error(str(error))
    selected = set(options.only) or {name for name, _, _ in registry}
    result = {
        "schema": 1,
        "started": datetime.now(timezone.utc).isoformat(),
        "system": system,
        "repository": str(repository),
        "selection": sorted(selected),
        "coverage": "partial",
        "checks": [],
        "status": "incomplete",
    }
    write_report(report, result)
    interrupted = False
    for name, command, missing in registry:
        entry = {"name": name, "command": command, "selected": name in selected}
        if name not in selected:
            entry.update(status="skip", reason="Not selected by --only")
        elif interrupted:
            entry.update(status="skip", reason="Suite interrupted before this check")
        elif missing:
            entry.update(status="missing-prerequisite", reason=missing)
        else:
            try:
                entry.update(run_check(name, command, report, options.timeout))
            except KeyboardInterrupt:
                entry.update(
                    status="interrupted", reason="Interrupted before check started"
                )
            interrupted = entry["status"] == "interrupted"
        result["checks"].append(entry)
        if "log" not in entry:
            print(f"{entry['status'].upper()} {name}: {entry['reason']}", flush=True)
        write_report(report, result)
    selected_statuses = {
        check["status"] for check in result["checks"] if check["selected"]
    }
    if interrupted:
        result["status"] = "interrupted"
    elif selected_statuses & {"fail", "timeout"}:
        result["status"] = "fail"
    elif selected_statuses == {"pass"}:
        result["status"] = "pass"
    if all(
        check["status"] in ("pass", "fail") and "returncode" in check
        for check in result["checks"]
    ):
        result["coverage"] = "full"
    result["finished"] = datetime.now(timezone.utc).isoformat()
    write_report(report, result)
    print(
        f"{result['status'].upper()} ({result['coverage']} coverage): {report / 'report.json'}"
    )
    return {"pass": 0, "fail": 1, "incomplete": 2, "interrupted": 130}[result["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
