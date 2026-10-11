from concurrent.futures import ThreadPoolExecutor
import ipaddress
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import builder
import guest
import workspace
import native_check


class BuilderTests(unittest.TestCase):
    def test_storage_admission_counts_owned_vms_and_enforces_both_disk_floors(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            storage = root / "vms"
            storage.mkdir()
            (storage / "human-vm").mkdir()
            config = {"tart_home": str(root), "record_root": str(root)}
            with patch.object(
                builder.shutil,
                "disk_usage",
                return_value=SimpleNamespace(free=11 * 1024**3),
            ):
                for number in range(8):
                    builder._admit_storage(config)
                    (storage / ("build-" + f"{number:032x}")).mkdir()
                with self.assertRaisesRegex(
                    builder.BuilderError, "review and explicitly remove"
                ):
                    builder._admit_storage(config)
                self.assertTrue((storage / "human-vm").is_dir())
                for invalid in (0, 65, True):
                    with self.assertRaisesRegex(
                        builder.BuilderError, "max_retained_vms"
                    ):
                        builder._admit_storage(dict(config, max_retained_vms=invalid))
            for values in ((9, 11), (11, 9)):
                with patch.object(
                    builder.shutil,
                    "disk_usage",
                    side_effect=[
                        SimpleNamespace(free=value * 1024**3) for value in values
                    ],
                ):
                    with self.assertRaisesRegex(builder.BuilderError, "free space"):
                        builder._check_free_space(config)
            with self.assertRaisesRegex(builder.BuilderError, "min_free_bytes"):
                builder._check_free_space(dict(config, min_free_bytes=0))

    def test_shared_storage_lock_prevents_concurrent_quota_admission(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "vms").mkdir()
            config = {
                "tart_home": str(root),
                "record_root": str(root),
                "max_retained_vms": 1,
            }

            def build_job(*args):
                time.sleep(0.05)
                (root / "vms" / ("build-" + "a" * 32)).mkdir()
                return {"status": "completed"}

            with (
                patch.object(
                    builder.shutil,
                    "disk_usage",
                    return_value=SimpleNamespace(free=11 * 1024**3),
                ),
                patch.object(builder, "_build_locked", side_effect=build_job) as run,
                ThreadPoolExecutor(max_workers=2) as pool,
            ):
                futures = [
                    pool.submit(builder.build, dict(config), {}) for _ in range(2)
                ]
                results = []
                for future in futures:
                    try:
                        results.append(future.result(timeout=5))
                    except builder.BuilderError as error:
                        results.append(str(error))
            self.assertEqual(run.call_count, 1)
            self.assertEqual(sum(isinstance(result, dict) for result in results), 1)
            self.assertTrue(
                any(
                    isinstance(result, str) and "limit 1" in result
                    for result in results
                )
            )

    def test_default_deny_public_policy_and_host_exclusion(self):
        local = {ipaddress.IPv4Network("11.1.0.0/16")}
        policy = builder.network_policy(
            ["1.1.1.1/32", "8.8.8.8/32"], ["1.1.1.1"], local
        )
        self.assertIn("--net-softnet-block=0.0.0.0/0,@host", policy)
        self.assertIn("--net-softnet-allow=out 1.1.1.1/32,out 8.8.8.8/32", policy)
        for cidr in (
            "0.0.0.0/0",
            "10.0.0.0/8",
            "11.1.2.0/24",
            "169.254.169.254/32",
            "168.63.129.16/32",
            "192.168.0.0/16",
            "100.100.100.200/32",
            "::/0",
            "8.8.8.8/24",
        ):
            with self.subTest(cidr=cidr), self.assertRaises(builder.BuilderError):
                builder.network_policy([cidr], ["1.1.1.1"], local)
        with self.assertRaises(builder.BuilderError):
            builder.network_policy(["1.1.1.1/32"], ["192.168.1.1"], local)

    def test_no_host_shares_or_default_network(self):
        args = builder.run_arguments(
            "build-fixture", builder.network_policy(["1.1.1.1/32"], ["1.1.1.1"], set())
        )
        for flag in (
            "--no-clipboard",
            "--no-audio",
            "--no-usb-accessories",
            "--no-graphics",
            "--net-softnet",
        ):
            self.assertIn(flag, args)
        self.assertFalse(
            any(
                value.startswith(
                    ("--dir", "--disk", "--net-bridged", "--net-host", "--vnc")
                )
                for value in args
            )
        )

    def test_command_is_data_and_requires_supported_executable(self):
        command = ["nix", "build", "--expr", 'builtins.abort "$(touch /tmp/no)"']
        self.assertEqual(builder.command_arguments(command), command)
        for value in (
            [],
            "nix build",
            ["sh", "-c", "true"],
            ["nix", "bad\0argument"],
            ["nix"] * 257,
        ):
            with self.assertRaises(builder.BuilderError):
                builder.command_arguments(value)

    def test_materialized_path_flake_selection(self):
        worktree = "/private/tmp/guest/worktree"
        self.assertEqual(
            guest.build_arguments(["nix", "build", "--no-link"], worktree, True),
            ["nix", "build", "--no-link", "path:" + worktree],
        )
        self.assertEqual(
            guest.build_arguments(
                ["nix", "build", ".#pkg", "--file", "x.nix"], worktree, True
            ),
            ["nix", "build", "path:" + worktree + "#pkg", "--file", "x.nix"],
        )
        self.assertEqual(
            guest.build_arguments(["nix", "build", "--expr", "value"], worktree, True),
            ["nix", "build", "--expr", "value"],
        )
        self.assertEqual(
            guest.build_arguments(["nix", "build", ".#pkg"], worktree, False),
            ["nix", "build", ".#pkg"],
        )
        self.assertEqual(
            guest.build_arguments(["nix", "build", "."], worktree, True),
            ["nix", "build", "path:" + worktree],
        )
        self.assertEqual(
            guest.build_arguments(["nix", "eval", "--json", ".#value"], worktree, True),
            ["nix", "eval", "--json", "path:" + worktree + "#value"],
        )

    def test_probe_builder_is_a_store_input_not_a_profile_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = Path(temporary) / "nix/store/abc-python3-3.13.15/bin"
            store.mkdir(parents=True)
            (store / "python3.13").write_text("")
            link = Path(temporary) / "profile-python3"
            link.symlink_to(store / "python3.13")
            with patch.object(
                guest.os.path,
                "realpath",
                return_value="/nix/store/abc-python3-3.13.15/bin/python3.13",
            ):
                self.assertEqual(
                    guest.store_builder(link),
                    '"${builtins.storePath "/nix/store/abc-python3-3.13.15"}/bin/python3.13"',
                )
            with self.assertRaisesRegex(RuntimeError, "Nix store"):
                guest.store_builder("/usr/bin/python3")

    def test_guest_materialization_refuses_symlink_parent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "payload"
            source.write_bytes(b"synthetic materialized font")
            item = {
                "payload": "payload",
                "target": "fonts/private.otf",
                "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            }
            worktree = root / "worktree"
            worktree.mkdir()
            manifest = {"workspace": str(worktree), "protected_paths": [item["target"]]}
            guest.materialize(root, manifest, [item])
            self.assertEqual(
                (worktree / item["target"]).read_bytes(), source.read_bytes()
            )
            other = root / "other"
            other.mkdir()
            attack = root / "attack"
            attack.mkdir()
            (attack / "fonts").symlink_to(other, target_is_directory=True)
            manifest["workspace"] = str(attack)
            with self.assertRaises(OSError):
                guest.materialize(root, manifest, [item])
            self.assertFalse((other / "private.otf").exists())

    def test_changed_host_interfaces_abort_collection(self):
        process = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(10)"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            with (
                tempfile.TemporaryFile() as log,
                patch.object(
                    builder,
                    "host_networks",
                    return_value=({ipaddress.IPv4Network("10.0.0.0/8")}, set()),
                ),
            ):
                with self.assertRaisesRegex(
                    builder.BuilderError, "configuration changed"
                ):
                    builder._collect(process, log, log, float("inf"), set())
        finally:
            process.terminate()
            process.wait()
            process.stdout.close()
            process.stderr.close()

    def test_workload_streams_remain_separate(self):
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                'import os; os.write(1,b"{\\"answer\\":42}\\n"); os.write(2,b"diagnostic\\n")',
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            with (
                tempfile.TemporaryFile() as stdout,
                tempfile.TemporaryFile() as stderr,
                patch.object(builder, "host_networks", return_value=(set(), set())),
            ):
                self.assertEqual(
                    builder._collect(process, stdout, stderr, float("inf"), set()), 0
                )
                stdout.seek(0)
                stderr.seek(0)
                self.assertEqual(stdout.read(), b'{"answer":42}\n')
                self.assertEqual(stderr.read(), b"diagnostic\n")
        finally:
            process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()

    def test_low_storage_aborts_running_workload_collection(self):
        process = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(10)"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            with (
                tempfile.TemporaryFile() as log,
                patch.object(
                    builder.shutil,
                    "disk_usage",
                    return_value=SimpleNamespace(free=1024**3),
                ),
            ):
                with self.assertRaisesRegex(builder.BuilderError, "free space"):
                    builder._collect(
                        process,
                        log,
                        log,
                        float("inf"),
                        set(),
                        storage={"tart_home": "/unused", "record_root": "/unused"},
                    )
        finally:
            process.terminate()
            process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()

    def test_vm_output_is_bounded_and_terminates_vm(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "vm.log"
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    "import os,time; os.write(1,b'x'*8192); time.sleep(10)",
                ],
                stdout=subprocess.PIPE,
            )
            errors = []
            try:
                with patch.object(builder, "MAX_LOG_BYTES", 1024):
                    builder._copy_vm_log(process, output, errors)
                process.wait(timeout=5)
                self.assertEqual(output.stat().st_size, 1024)
                self.assertEqual(errors, ["Native VM exceeded its output limit"])
                self.assertNotEqual(process.returncode, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdout.close()

    def test_native_check_builds_its_own_materialized_source_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(
                builder, "build", return_value={"status": "completed"}
            ) as build:
                report = native_check.check({"record_root": temporary})
            self.assertEqual(report["status"], "pass")
            config, admitted, args = build.call_args.args
            item = config["materialized_inputs"][0]
            self.assertEqual(Path(item["source"]).read_bytes(), b"materialized fixture")
            fixture = Path(report["fixture"])
            expression = (fixture / "worker/worktree/default.nix").read_text()
            command = expression.split('args = [ "-euc" ', 1)[1].split(" ];", 1)[0]
            self.assertEqual(
                json.loads(command),
                'test "$font" = "materialized fixture"; clang $src -o $out; $out',
            )
            self.assertNotIn("--rebuild", args)
            self.assertEqual(args[-2:], ["--file", "default.nix"])
            self.assertTrue(Path(admitted["quarantine"]).is_dir())
            with patch.object(builder, "build", return_value={"status": "completed"}):
                second = native_check.check({"record_root": temporary})
            second_fixture = Path(second["fixture"])
            second_expression = (
                second_fixture / "worker/worktree/default.nix"
            ).read_text()
            self.assertIn(fixture.name, expression)
            self.assertIn(second_fixture.name, second_expression)
            self.assertNotEqual(expression, second_expression)

    def test_export_uses_only_admitted_objects_and_keeps_quarantine_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            env = workspace._environment()

            def git(*args):
                return (
                    subprocess.check_output(
                        [workspace.GIT, "-C", str(source), *args], env=env
                    )
                    .decode()
                    .strip()
                )

            git("init", "-q", "-b", "main")
            (source / "plain").write_text("ordinary source")
            (source / ".gitattributes").write_text("*.sec filter=git-crypt\n")
            (source / "protected.sec").write_bytes(b"\0GITCRYPT\0ciphertext")
            git("add", ".")
            git("commit", "-qm", "Fixture")
            session = workspace.create(source, root / "worker", "agent")
            bare = root / "admitted" / "repository.git"
            bare.parent.mkdir()
            workspace._init_bare(bare, session["snapshot_commit"])
            workspace._fetch_bundle(bare, session["base_bundle"], "refs/review/result")
            before = workspace._text(bare, "show-ref")
            record = root / "record"
            record.mkdir()
            request = {"command_args": ["nix", "build"]}
            archive = builder._payload(
                {"quarantine": str(bare.parent), "tip": session["snapshot_commit"]},
                record,
                request,
            )
            self.assertEqual(workspace._text(bare, "show-ref"), before)
            with tarfile.open(archive) as payload:
                self.assertEqual(
                    set(payload.getnames()),
                    {"source.bundle", "request.json", "workspace.py", "guest.py"},
                )
                data = json.load(payload.extractfile("request.json"))
                self.assertEqual(data["protected_paths"], ["protected.sec"])
                self.assertEqual(data["snapshot_commit"], session["snapshot_commit"])
            self.assertFalse((record / "export.git/objects/info/alternates").exists())
            materialized = root / "font-input"
            materialized.write_bytes(b"synthetic plaintext font")
            record2 = root / "record-materialized"
            record2.mkdir()
            item = {
                "source": str(materialized.resolve()),
                "target": "protected.sec",
                "sha256": hashlib.sha256(materialized.read_bytes()).hexdigest(),
            }
            archive = builder._payload(
                {"quarantine": str(bare.parent), "tip": session["snapshot_commit"]},
                record2,
                {},
                [item],
            )
            with tarfile.open(archive) as payload:
                self.assertEqual(
                    payload.extractfile("materialized-0").read(),
                    materialized.read_bytes(),
                )
                data = json.load(payload.extractfile("request.json"))
                self.assertEqual(
                    data["materialized_inputs"][0]["target"], "protected.sec"
                )
                self.assertNotIn("source", data["materialized_inputs"][0])
            materialized.write_text("changed after authorization")
            record3 = root / "record-changed"
            record3.mkdir()
            with self.assertRaisesRegex(builder.BuilderError, "changed"):
                builder._payload(
                    {"quarantine": str(bare.parent), "tip": session["snapshot_commit"]},
                    record3,
                    {},
                    [item],
                )


if __name__ == "__main__":
    unittest.main()
