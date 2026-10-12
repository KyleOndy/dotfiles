import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "suite", Path(__file__).with_name("test-alamode.py")
)
suite = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(suite)


class SuiteTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="alamode-suite-test-")
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def check(self, name, source, timeout=5):
        with redirect_stdout(io.StringIO()):
            return suite.run_check(
                name, [sys.executable, "-c", source], self.root, timeout
            )

    def main(self, registry, *arguments):
        report = self.root / "report"
        with (
            patch.object(suite.platform, "system", return_value="Darwin"),
            patch.object(suite.platform, "machine", return_value="arm64"),
            patch.object(suite, "checks", return_value=iter(registry)),
            redirect_stdout(io.StringIO()),
        ):
            code = suite.main(["--report", str(report), *arguments])
        return code, json.loads((report / "report.json").read_text())

    def test_success_failure_and_evidence(self):
        passed = self.check("passed", "print('fixture evidence')")
        failed = self.check(
            "failed", "import sys; print('fixture failure'); sys.exit(7)"
        )
        self.assertEqual((passed["status"], passed["returncode"]), ("pass", 0))
        self.assertEqual((failed["status"], failed["returncode"]), ("fail", 7))
        self.assertEqual(Path(passed["log"]).read_text(), "fixture evidence\n")
        self.assertIn("fixture failure", Path(failed["log"]).read_text())

    def test_timeout_kills_descendants_after_leader_exits(self):
        heartbeat = self.root / "heartbeat"
        child = f"import signal,time; signal.signal(signal.SIGINT, signal.SIG_IGN); f=open({str(heartbeat)!r},'ab',buffering=0)\nwhile True: f.write(b'.'); time.sleep(.01)"
        source = f"import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',{child!r}]); time.sleep(.1)"
        with patch.object(suite, "STOP_GRACE_SECONDS", 0.1):
            result = self.check("timeout", source, timeout=0.3)
        self.assertEqual(result["status"], "timeout")
        self.assertLess(result["seconds"], 2)
        before = heartbeat.stat().st_size
        time.sleep(0.1)
        self.assertEqual(heartbeat.stat().st_size, before)

    def test_bounded_log_fails(self):
        with patch.object(suite, "MAX_LOG_BYTES", 128):
            result = self.check("large", "print('x' * 4096)")
        self.assertEqual(result["status"], "fail")
        self.assertIn("log limit", result["reason"])
        self.assertEqual(Path(result["log"]).stat().st_size, 128)

    def test_skip_and_missing_prerequisite_protocol(self):
        for status in ("skip", "missing-prerequisite"):
            with self.subTest(status=status):
                result = self.check(
                    status,
                    f"import json,sys; print('fixture preamble'); print(json.dumps({{'status':{status!r},'reason':'fixture unavailable'}},indent=2)); sys.exit(2)",
                )
                self.assertEqual(result["status"], status)
                self.assertEqual(result["reason"], "fixture unavailable")
        result = self.check(
            "real-failure", 'import sys; print(\'{"status":"skip"}\'); sys.exit(1)'
        )
        self.assertEqual(result["status"], "fail")
        with redirect_stdout(io.StringIO()):
            result = suite.run_check(
                "missing-command", [str(self.root / "absent-command")], self.root, 1
            )
        self.assertEqual(result["status"], "missing-prerequisite")
        self.assertTrue(Path(result["log"]).exists())

    def test_selected_scope_and_prerequisites(self):
        registry = [
            ("selected", [sys.executable, "-c", "print('selected fixture')"], None),
            ("unselected", ["must-not-run"], "fixture missing"),
        ]
        code, report = self.main(registry, "--only", "selected")
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["coverage"], "partial")
        self.assertEqual(report["selection"], ["selected"])
        self.assertEqual(report["checks"][1]["status"], "skip")
        self.assertFalse(report["checks"][1]["selected"])

    def test_missing_prerequisite_is_incomplete(self):
        code, report = self.main(
            [("builder", ["must-not-run"], "Builder fixture not provisioned")]
        )
        self.assertEqual(code, 2)
        self.assertEqual(report["status"], "incomplete")
        self.assertEqual(report["coverage"], "partial")
        self.assertEqual(report["checks"][0]["status"], "missing-prerequisite")

    def test_full_pass_and_failure_exit_codes(self):
        for exit_code, expected in ((0, 0), (3, 1)):
            with self.subTest(exit_code=exit_code):
                path = self.root / "report"
                if path.exists():
                    for child in path.iterdir():
                        child.unlink()
                    path.rmdir()
                code, report = self.main(
                    [
                        (
                            "fixture",
                            [sys.executable, "-c", f"raise SystemExit({exit_code})"],
                            None,
                        )
                    ]
                )
                self.assertEqual(code, expected)
                self.assertEqual(report["status"], "pass" if expected == 0 else "fail")
                self.assertEqual(report["coverage"], "full")

    def test_interrupt_records_current_and_remaining_checks(self):
        report = self.root / "interrupted-report"
        heartbeat = self.root / "heartbeat"
        child = f"import time; f=open({str(heartbeat)!r},'ab',buffering=0)\nwhile True: f.write(b'.'); time.sleep(.01)"
        registry = [
            ("active", [sys.executable, "-c", child], None),
            ("pending", ["must-not-run"], None),
        ]
        source = f"""import importlib.util,sys
s=importlib.util.spec_from_file_location("suite",{str(Path(suite.__file__))!r})
m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
m.platform.system=lambda:"Darwin"
m.platform.machine=lambda:"arm64"
m.checks=lambda *args:iter({registry!r})
sys.exit(m.main(["--report",{str(report)!r}]))
"""
        process = subprocess.Popen(
            [sys.executable, "-c", source],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            deadline = time.monotonic() + 5
            while not heartbeat.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(heartbeat.exists())
            process.send_signal(signal.SIGINT)
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 130, stdout + stderr)
            result = json.loads((report / "report.json").read_text())
            self.assertEqual(result["status"], "interrupted")
            self.assertEqual(
                [entry["status"] for entry in result["checks"]], ["interrupted", "skip"]
            )
            before = heartbeat.stat().st_size
            time.sleep(0.1)
            self.assertEqual(heartbeat.stat().st_size, before)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate()

    def test_unsupported_platform_fails_before_checks(self):
        with (
            patch.object(suite.platform, "system", return_value="unsupported"),
            patch.object(suite, "checks") as registry,
            redirect_stderr(io.StringIO()) as error,
        ):
            with self.assertRaises(SystemExit) as result:
                suite.main([])
        self.assertEqual(result.exception.code, 2)
        self.assertIn("requires Darwin", error.getvalue())
        registry.assert_not_called()


if __name__ == "__main__":
    unittest.main()
