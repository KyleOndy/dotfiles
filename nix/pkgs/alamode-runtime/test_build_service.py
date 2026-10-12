import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

import common
from common import request
from build_client import snapshot
import workspace


class BuildServiceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="alamode-build-service-")
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "source"
        self.source.mkdir()
        self.git(self.source, "init", "-q", "-b", "main")
        (self.source / ".gitattributes").write_text("*.sec filter=git-crypt\n")
        (self.source / "protected.sec").write_bytes(b"\0GITCRYPT\0fixture ciphertext\n")
        (self.source / "plain").write_text("before\n")
        self.git(self.source, "add", ".")
        self.git(self.source, "commit", "-qm", "Fixture baseline")
        (self.root / "control/records").mkdir(parents=True, mode=0o700)
        self.manifest = workspace.create(
            self.source,
            self.root / "session",
            "agent",
            record_root=self.root / "control/records/fixture",
        )
        self.module = self.root / "builder.py"
        self.module.write_text("""import json,time
from pathlib import Path
import workspace
def build(config, admitted, args):
 record=Path(config['record_root'])/'build-fixture'
 record.mkdir()
 (record/'args.json').write_text(json.dumps(args))
 output=b'/nix/store/fixture-output\\n' if '--print-out-paths' in args else b'x'*config.get('output_bytes',70000)+b'\\xff\\n'+workspace._text(Path(admitted['quarantine'])/'repository.git','show',admitted['tip']+':plain').encode()+b'\\n' if '--raw' in args or 'build' in args else b'{"result":42}\\n'
 (record/'stdout.log').write_bytes(output)
 (record/'stderr.log').write_text('fixture diagnostics\\n')
 try:
  if '--slow' in args: time.sleep(2)
 finally: (record/'cleanup').touch()
 return {'status':'completed','returncode':0,'record':str(record)}
""")
        self.environment = patch.dict(
            os.environ,
            PYTHONPATH=os.pathsep.join(
                [
                    str(Path(common.__file__).parent),
                    str(Path(workspace.__file__).parent),
                ]
            ),
        )
        self.environment.start()
        package = self.root / "package"
        package.mkdir()
        for module in (
            Path(__file__).with_name("build_service.py"),
            Path(common.__file__),
            Path(workspace.__file__),
            Path(__file__).with_name("build_client.py"),
        ):
            shutil.copyfile(module, package / module.name)
        spec = importlib.util.spec_from_file_location(
            "fixture_build_service", package / "build_service.py"
        )
        loaded = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(loaded)
        self.service_class = loaded.BuildService
        self.service = self.service_class(
            {"record_root": str(self.root / "builder-records")},
            self.manifest,
            self.root / "service",
            self.module,
        )

    def tearDown(self):
        self.service.close()
        self.environment.stop()
        self.temporary.cleanup()

    def git(self, directory, *args):
        return (
            subprocess.check_output(
                [workspace.GIT, "-C", str(directory), *args],
                env=workspace._environment(),
            )
            .decode()
            .strip()
        )

    def capture(self):
        temporary = Path(self.manifest["session_root"]) / (
            "snapshot-" + uuid.uuid4().hex
        )
        temporary.mkdir()
        return snapshot(self.service.client, temporary)

    def call(self, op, identifier, **fields):
        return request(
            self.service.socket,
            self.service.token,
            {"op": op, "id": identifier, **fields},
        )

    def wait(self, identifier):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            status = self.call("status", identifier)
            if status["state"] in ("completed", "failed", "cancelled", "lost"):
                return status
            time.sleep(0.02)
        self.fail("Build did not finish")

    def test_dirty_snapshot_preserves_head_index_and_protected_files(self):
        work = Path(self.manifest["workspace"])
        head = self.git(work, "rev-parse", "HEAD")
        index = Path(self.manifest["git_dir"]) / "index"
        previous = hashlib.sha256(index.read_bytes()).hexdigest()
        (work / "plain").write_text("dirty source\n")
        (work / "untracked").write_text("include untracked\n")
        bundle, tip = self.capture()
        self.assertEqual(self.git(work, "rev-parse", "HEAD"), head)
        self.assertEqual(hashlib.sha256(index.read_bytes()).hexdigest(), previous)
        identifier = uuid.uuid4().hex
        body = {
            "bundle": str(bundle),
            "tip": tip,
            "args": ["build", "--expr", 'builtins.abort "$(not-a-host-command)"'],
        }
        first = self.call("start", identifier, **body)
        self.assertEqual(first, self.call("start", identifier, **body))
        status = self.wait(identifier)
        self.assertEqual(status["state"], "completed", status)
        record = Path(status["record"])
        admitted = json.loads((record / "request.json").read_text())["admitted"]
        bare = Path(admitted["quarantine"]) / "repository.git"
        self.assertEqual(workspace._text(bare, "show", tip + ":plain"), "dirty source")
        self.assertEqual(
            workspace._text(bare, "show", tip + ":untracked"), "include untracked"
        )
        self.assertEqual(
            workspace._git(bare, "show", tip + ":protected.sec").stdout,
            b"\0GITCRYPT\0fixture ciphertext\n",
        )
        self.assertTrue(status["more"])
        rest = self.call("status", identifier, offset=status["offset"])
        self.assertIn(b"dirty source", base64.b64decode(rest["output"]))
        self.assertEqual(base64.b64decode(status["stderr"]), b"fixture diagnostics\n")
        self.assertFalse(rest["more"])

    def test_auth_command_limit_cancel_and_global_build_slot(self):
        bundle, tip = self.capture()
        identifier = uuid.uuid4().hex
        with self.assertRaisesRegex(ValueError, "Unauthorized"):
            request(self.service.socket, "wrong", {"op": "start", "id": identifier})
        refused = self.call(
            "start",
            identifier,
            bundle=str(bundle),
            tip=tip,
            args=["shell", "nixpkgs#bash"],
        )
        self.assertEqual(refused["receipt"], "failed")
        identifier = uuid.uuid4().hex
        self.call(
            "start", identifier, bundle=str(bundle), tip=tip, args=["build", "--slow"]
        )
        busy = self.call(
            "start",
            uuid.uuid4().hex,
            bundle=str(bundle),
            tip=tip,
            args=["eval", ".#value"],
        )
        self.assertEqual(busy["receipt"], "failed")
        deadline = time.monotonic() + 5
        while (
            not list((self.service.root / identifier / "vm").glob("build-*/stdout.log"))
            and time.monotonic() < deadline
        ):
            time.sleep(0.01)
        with self.service_class(
            self.service.config, self.manifest, self.root / "service-other", self.module
        ) as other:
            second = uuid.uuid4().hex
            request(
                other.socket,
                other.token,
                {
                    "op": "start",
                    "id": second,
                    "bundle": str(bundle),
                    "tip": tip,
                    "args": ["eval", ".#value"],
                },
            )
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                result = request(
                    other.socket, other.token, {"op": "status", "id": second}
                )
                if result["state"] == "failed":
                    break
                time.sleep(0.02)
            self.assertIn("capacity", result["error"])
        self.call("cancel", identifier)
        self.assertEqual(self.wait(identifier)["state"], "cancelled")

    def test_client_sigterm_cancels_worker_and_runs_cleanup(self):
        config = Path(self.manifest["session_root"]) / "build.json"
        config.write_text(json.dumps(self.service.client))
        process = subprocess.Popen(
            [
                sys.executable,
                "-I",
                str(self.root / "package/build_client.py"),
                "build",
                "--slow",
            ],
            env={
                **os.environ,
                "ALAMODE_BUILD_CLIENT": str(config),
                "TMPDIR": self.manifest["session_root"],
            },
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            deadline = time.monotonic() + 5
            while (
                not list(self.service.root.glob("*/vm/build-*/stdout.log"))
                and time.monotonic() < deadline
            ):
                time.sleep(0.01)
            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 130, stdout + stderr)
            deadline = time.monotonic() + 5
            while (
                not list(self.service.root.glob("*/vm/build-*/cleanup"))
                and time.monotonic() < deadline
            ):
                time.sleep(0.01)
            self.assertEqual(
                len(list(self.service.root.glob("*/vm/build-*/cleanup"))), 1
            )
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_client_preserves_json_and_raw_stdout_separately_from_diagnostics(self):
        config = Path(self.manifest["session_root"]) / "build.json"
        config.write_text(json.dumps(self.service.client))
        for command, flag, expected in (
            ("eval", "--json", b'{"result":42}\n'),
            ("eval", "--raw", b"x" * 70000 + b"\xff\nbefore\n"),
            ("build", "--print-out-paths", b"/nix/store/fixture-output\n"),
        ):
            result = subprocess.run(
                [
                    sys.executable,
                    "-I",
                    str(self.root / "package/build_client.py"),
                    command,
                    flag,
                    ".#value",
                ],
                env={
                    **os.environ,
                    "ALAMODE_BUILD_CLIENT": str(config),
                    "TMPDIR": self.manifest["session_root"],
                },
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)
            self.assertIn(b"fixture diagnostics", result.stderr)
            self.assertIn(b"alamode build record:", result.stderr)

    @unittest.skipUnless(
        sys.platform == "darwin" and os.environ.get("ALAMODE_NATIVE_TESTS") == "1",
        "Requires the native macOS sandbox",
    )
    def test_native_sandbox_client_admits_dirty_snapshot_without_trusted_state_access(
        self,
    ):
        from test_session import configuration, session

        config = configuration(self.root)
        source = Path(
            os.environ.get(
                "ALAMODE_SANDBOX_RUNNER_SOURCE", Path(__file__).with_name("sandbox.mjs")
            )
        ).read_text()
        Path(config["sandboxRunner"]).write_text(
            source.replace("@sandboxRuntime@", os.environ["ALAMODE_SANDBOX_RUNTIME"])
        )
        options = session.parse([], config)
        policy = session.policy(options, config, self.root)
        policy["read"].append(str(self.root / "package"))
        self.service.config["output_bytes"] = 32
        manifest = {
            "id": "fixture",
            "workspace": self.manifest,
            "policy": policy,
            "build_socket": self.service.socket,
        }
        runtime = Path(self.manifest["session_root"]) / "runtime"
        for name in ("home", "tmp", "cache", "agent", "state"):
            (runtime / name).mkdir(parents=True, exist_ok=True)
        client = runtime / "build.json"
        client.write_text(json.dumps(self.service.client))
        environment = session.child_environment(config, manifest, self.root, runtime)
        environment["ALAMODE_BUILD_CLIENT"] = str(client)
        work = Path(self.manifest["workspace"])
        (work / "plain").write_text("native dirty source\n")
        probe = f"""import pathlib,subprocess,sys
for denied in {repr([str(self.service.root / "builds.sqlite"), str(self.source / "plain")])}:
 try: pathlib.Path(denied).read_bytes()
 except OSError: pass
 else: raise AssertionError('Sandbox exposed '+denied)
result=subprocess.run([sys.executable,'-I',{str(self.root / "package/build_client.py")!r},'build','.'],capture_output=True)
assert result.returncode==0,result.stdout+result.stderr
assert b'native dirty source' in result.stdout,result.stdout
"""
        status = session.execute(
            config, manifest, [sys.executable, "-c", probe], environment, runtime
        )
        self.assertEqual(status, 0)


if __name__ == "__main__":
    unittest.main()
