import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "alamode-runtime"))
import workspace
from broker import Broker
from common import Store, atomic_json, lock_file, request, socket_path, wait_socket

ROOT = Path(__file__).resolve().parent


class BrokerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="alamode-coordinator-test-")
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.git(self.source, "init", "-q", "-b", "main")
        (self.source / "file").write_text("baseline\n")
        self.git(self.source, "add", ".")
        self.git(self.source, "commit", "-qm", "baseline")
        parent = workspace.create(self.source, self.root / "parent", "parent")
        launcher = self.root / "launcher"
        launcher.write_text(
            f"#!{sys.executable}\nimport os,sys\nos.execv(sys.executable,[sys.executable,{str(ROOT / 'fake_pi.py')!r},*sys.argv[1:]])\n"
        )
        launcher.chmod(0o700)
        self.directory = self.root / "coord"
        self.directory.mkdir()
        self.config = {
            "directory": str(self.directory),
            "coordinator": "test",
            "repo_dir": parent["workspace"],
            "launcher": str(launcher),
            "socket": socket_path(self.directory),
            "token": "coordinator-token",
            "manifest": {
                "workspace": parent,
                "builder": {
                    "base_vm": "pinned-fixture",
                    "record_root": str(self.root / "builds"),
                },
            },
            "policy": {
                "session_root": str(self.root / "children"),
                "allowed_models": ["fixture"],
                "nix": True,
            },
            "pool": str(self.root / "pool"),
            "max_agents": 1,
            "max_workers": 3,
        }
        atomic_json(self.directory / "broker.json", self.config)
        self.processes = []
        self.broker = self.launch("--serve", self.directory / "broker.json")
        try:
            wait_socket(self.config["socket"], self.config["token"], self.broker)
        except Exception:
            for log in self.root.glob("*.log"):
                print(log.read_text(), file=sys.stderr)
            raise

    def git(self, where, *args):
        return subprocess.run(
            [workspace.GIT, "-C", str(where), *args],
            env=workspace._environment(),
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()

    def launch(self, mode, config):
        log = open(self.root / (uuid.uuid4().hex + ".log"), "wb")
        env = dict(os.environ)
        env["PYTHONPATH"] = str(Path(workspace.__file__).parent)
        env["ALAMODE_COORD_TOKEN"] = "must-not-reach-child"
        process = subprocess.Popen(
            [sys.executable, str(ROOT / "broker.py"), mode, str(config)],
            env=env,
            stdout=log,
            stderr=log,
            start_new_session=True,
        )
        log.close()
        self.processes.append(process)
        return process

    def call(self, op, **fields):
        return request(
            self.config["socket"],
            self.config["token"],
            {"op": op, "id": str(uuid.uuid4()), **fields},
        )

    def settled(self, agent="alpha", desired="idle"):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            state = self.call("status", agent=agent)
            if state["state"] == desired:
                return state
            time.sleep(0.03)
        self.fail(f"{agent}: expected {desired}, got {state}")

    def tearDown(self):
        for config_file in self.directory.glob("agents/*/supervisor.json"):
            config = json.loads(config_file.read_text())
            try:
                request(
                    config["socket"],
                    config["token"],
                    {"op": "close", "id": str(uuid.uuid4())},
                    timeout=8,
                )
            except Exception:
                pass
            # Only processes launched by this fixture can hold these private locks.
            state = (
                self.directory / "agents" / config_file.parent.name / "supervisor.pid"
            )
            if state.exists():
                try:
                    os.kill(int(state.read_text()), signal.SIGTERM)
                except ProcessLookupError:
                    pass
            Path(config["socket"]).unlink(missing_ok=True)
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
        Path(self.config["socket"]).unlink(missing_ok=True)
        self.temporary.cleanup()

    def test_disconnect_deduplication_and_broker_restart(self):
        body = {"agent": "alpha", "task": "slow", "id": "stable-spawn"}
        first = self.call("spawn", **body)
        self.assertNotEqual(first.get("receipt"), "failed", first)
        self.assertEqual(first, self.call("spawn", **body))
        self.broker.kill()
        self.broker.wait()
        self.broker = self.launch("--serve", self.directory / "broker.json")
        wait_socket(self.config["socket"], self.config["token"], self.broker)
        state = self.settled()
        self.assertEqual(state["outcome"]["state"], "success")
        runtime = Path(first["workspace"]).parent / "runtime"
        self.assertEqual(
            len((runtime / "sessions/main.jsonl").read_text().splitlines()), 1
        )
        self.assertNotIn(
            "ALAMODE_COORD_TOKEN",
            json.loads((runtime / "environment.json").read_text()),
        )
        events = self.call("events", agent="alpha", after=0)["events"]
        self.assertEqual(
            sum(item["event"]["type"] == "agent_settled" for item in events), 1
        )
        self.assertEqual(
            self.call("events", agent="alpha", after=events[-1]["seq"])["events"], []
        )
        self.assertEqual(first, self.call("spawn", **body))

    def test_shutdown_stops_the_daemon_and_leaves_agents_running(self):
        self.call("spawn", agent="alpha", task="hi")
        self.settled()
        agent = Broker(self.config).agent("alpha")
        with self.assertRaisesRegex(ValueError, "Child capability"):
            request(
                self.config["socket"],
                agent["child_token"],
                {"op": "shutdown", "id": "child-shutdown"},
            )
        self.assertEqual(self.call("shutdown")["state"], "stopping")
        self.assertEqual(self.broker.wait(timeout=5), 0)
        self.assertFalse(Path(self.config["socket"]).exists())
        self.assertFalse((self.directory / "broker.pid").exists())
        os.kill(int((self.directory / "agents/alpha/supervisor.pid").read_text()), 0)
        self.broker = self.launch("--serve", self.directory / "broker.json")
        wait_socket(self.config["socket"], self.config["token"], self.broker)
        self.assertEqual(self.call("status", agent="alpha")["state"], "idle")

    def test_cap_steer_followup_interrupt_and_dialog(self):
        self.call("spawn", agent="alpha", task="hold")
        self.call("spawn", agent="beta", task="second")
        beta = self.call("status", agent="beta")
        self.assertEqual(beta["state"], "idle")
        self.assertIsNone(beta.get("outcome"))
        refused = self.call("send", agent="beta", message="no capacity")
        self.assertEqual(refused["receipt"], "failed")
        self.call("send", agent="alpha", message="queued", mode="follow_up")
        self.call("send", agent="alpha", message="steering", mode="steer")
        self.call("interrupt", agent="alpha")
        self.assertEqual(self.settled()["outcome"]["state"], "aborted")
        self.call("send", agent="beta", message="capacity freed")
        self.assertEqual(self.settled("beta")["outcome"]["state"], "success")
        self.call("send", agent="alpha", message="/question")
        waiting = self.settled(desired="waiting_input")
        self.assertIn("fixture-dialog", waiting["dialogs"])
        self.call("answer", agent="alpha", dialog="fixture-dialog", value="answer")
        self.settled()
        self.call("send", agent="alpha", message="/question")
        self.settled(desired="waiting_input")
        self.call("interrupt", agent="alpha")
        self.assertEqual(self.settled()["dialogs"], {})

    def test_activity_names_the_running_tool_inertly(self):
        self.call("spawn", agent="alpha", task="slow tool")
        deadline = time.monotonic() + 8
        while self.call("status", agent="alpha").get("activity") in (None, "thinking"):
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.03)
        self.assertEqual(
            self.call("status")["agents"][0]["activity"], "bash ls ]0;pwned -la rm"
        )
        self.assertNotIn(
            "tool_execution_start",
            [
                item["event"]["type"]
                for item in self.call("events", agent="alpha", after=0)["events"]
            ],
        )
        self.assertIsNone(self.settled()["activity"])

    def test_retention_cap_counts_closed_and_failed_agents_without_allocating(self):
        self.assertEqual(self.call("status")["limits"]["retained_agents"], 12)
        self.broker.terminate()
        self.broker.wait(timeout=5)
        self.config["max_retained_agents"] = 3
        atomic_json(self.directory / "broker.json", self.config)
        self.broker = self.launch("--serve", self.directory / "broker.json")
        wait_socket(self.config["socket"], self.config["token"], self.broker)
        preserved = []
        for name in ("alpha", "beta"):
            result = self.call("spawn", agent=name, task="complete")
            preserved.append(Path(result["workspace"]))
            self.settled(name)
            self.call("close", agent=name)
            self.settled(name, "closed")
        failed = self.call(
            "spawn",
            agent="failed",
            task="fail admission",
            bundle=str(self.root / "absent.bundle"),
            tip="0" * 40,
        )
        self.assertEqual(failed["receipt"], "failed")
        before = set((self.root / "children").iterdir())
        before_agents = set((self.directory / "agents").iterdir())
        refused = self.call("spawn", agent="excess", task="must not allocate")
        self.assertEqual(refused["receipt"], "failed")
        self.assertIn("retention limit (3)", refused["error"])
        self.assertIn("archive preserved work", refused["error"])
        self.assertEqual(set((self.root / "children").iterdir()), before)
        self.assertEqual(set((self.directory / "agents").iterdir()), before_agents)
        status = self.call("status")
        self.assertEqual(status["limits"]["retained_agents"], 3)
        self.assertEqual(
            {item["agent"]: item["state"] for item in status["agents"]},
            {"alpha": "closed", "beta": "closed", "failed": "failed"},
        )
        self.assertTrue(all(path.is_dir() for path in preserved))
        self.call("resume", agent="alpha")
        self.settled("alpha")
        self.call("send", agent="alpha", message="reuse retained work")
        self.assertEqual(self.settled("alpha")["outcome"]["state"], "success")

    def test_retention_limit_rejects_unbounded_or_invalid_configuration(self):
        for limit in (0, -1, 4097, True, "64"):
            with (
                self.subTest(limit=limit),
                self.assertRaisesRegex(ValueError, "max_retained_agents"),
            ):
                Broker({**self.config, "max_retained_agents": limit})

    def test_child_auth_model_policy_and_no_forge(self):
        rejected = self.call("spawn", agent="bad", task="test", model="unauthorized")
        self.assertEqual(rejected["receipt"], "failed")
        self.assertNotIn(
            "bad", {agent["agent"] for agent in self.call("status")["agents"]}
        )
        self.call("spawn", agent="alpha", task="hi")
        agent = Broker(self.config).agent("alpha")
        child_manifest = json.loads(Path(agent["manifest"]).read_text())
        self.assertEqual(child_manifest["builder"], self.config["manifest"]["builder"])
        self.assertTrue(child_manifest["policy"]["nix"])
        self.assertEqual(
            child_manifest["policy"]["allowed_models"],
            self.config["policy"]["allowed_models"],
        )
        with self.assertRaisesRegex(ValueError, "Child capability"):
            request(
                self.config["socket"],
                agent["child_token"],
                {"op": "spawn", "id": "bad", "agent": "other", "task": "escalate"},
            )
        with self.assertRaisesRegex(ValueError, "Unauthorized"):
            request(self.config["socket"], "wrong", {"op": "status"})
        request(
            self.config["socket"],
            agent["child_token"],
            {"op": "report", "id": "report", "message": "verified: PASS"},
        )
        result = self.call("result", agent="alpha")
        self.assertEqual(result["report"]["text"], "verified: PASS")
        self.assertIsNone(result["verification"])
        denied = self.call("spawn", agent="forge", task="test", size="small")
        self.assertEqual(denied["receipt"], "failed")

    def test_crash_resume_preserves_session_and_never_replays(self):
        first = self.call("spawn", agent="alpha", task="slow")
        runtime = Path(first["workspace"]).parent / "runtime"
        pid = int((runtime / "pid").read_text())
        os.kill(pid, signal.SIGKILL)
        self.settled(desired="lost")
        self.call("resume", agent="alpha")
        self.settled()
        self.assertEqual(
            len((runtime / "sessions/main.jsonl").read_text().splitlines()), 1
        )
        self.call("send", agent="alpha", message="resume explicitly")
        self.assertEqual(self.settled()["outcome"]["state"], "success")
        self.assertEqual(
            len((runtime / "sessions/main.jsonl").read_text().splitlines()), 2
        )
        self.call("teardown", agent="alpha")
        self.assertEqual(self.settled(desired="closed")["outcome"]["state"], "success")
        self.assertTrue(Path(first["workspace"]).exists())
        self.assertTrue((runtime / "sessions/main.jsonl").exists())

    def test_provider_error_empty_and_admitted_commits(self):
        self.call("spawn", agent="alpha", task="fail")
        self.assertEqual(self.settled()["outcome"]["state"], "error")
        self.call("send", agent="alpha", message="empty")
        self.assertEqual(self.settled()["outcome"]["state"], "empty")
        parent = self.config["manifest"]["workspace"]
        working = Path(parent["workspace"])
        (working / "file").write_text("parent committed change\n")
        self.git(working, "add", "file")
        self.git(working, "commit", "-qm", "parent work")
        tip = self.git(working, "rev-parse", "HEAD")
        bundle = working / "proposal.bundle"
        self.git(working, "bundle", "create", str(bundle), "HEAD")
        child = self.call("spawn", agent="beta", task="hi", bundle=str(bundle), tip=tip)
        self.assertNotEqual(child.get("receipt"), "failed", child)
        self.assertEqual(
            (Path(child["workspace"]) / "file").read_text(), "parent committed change\n"
        )

    def test_supervisor_crash_recovery_and_operation_collision(self):
        self.call("spawn", agent="alpha", task="slow", id="spawn-once")
        directory = self.directory / "agents" / "alpha"
        pid = int((directory / "supervisor.pid").read_text())
        os.kill(pid, signal.SIGKILL)
        self.settled(desired="lost")
        time.sleep(0.2)
        self.call("resume", agent="alpha")
        self.settled()
        duplicate = self.call("spawn", agent="alpha", task="slow", id="spawn-once")
        runtime = Path(duplicate["workspace"]).parent / "runtime"
        self.assertEqual(
            len((runtime / "sessions/main.jsonl").read_text().splitlines()), 1
        )
        with self.assertRaisesRegex(ValueError, "different arguments"):
            self.call("spawn", agent="alpha", task="changed", id="spawn-once")
        self.call("send", agent="alpha", message="fresh")
        self.assertEqual(self.settled()["outcome"]["state"], "success")

    def test_delegate_cli_uses_same_supervisor(self):
        script = Path(
            os.environ.get(
                "ALAMODE_DELEGATE_SCRIPT",
                str(ROOT.parent / "alamode-delegate/alamode-delegate.py"),
            )
        )
        if not script.exists():
            self.skipTest("ALAMODE_DELEGATE_SCRIPT is not set")
        env = {
            **os.environ,
            "ALAMODE_COORD_SOCKET": self.config["socket"],
            "ALAMODE_COORD_TOKEN": self.config["token"],
            "PYTHONPATH": str(ROOT),
            "ALAMODE_DELEGATE_WAIT_SECONDS": "5",
        }

        def delegate(*args):
            return subprocess.run(
                [sys.executable, str(script), *args],
                env=env,
                text=True,
                capture_output=True,
                timeout=10,
            )

        first = delegate("--edit", "--name", "alpha", "hello")
        self.assertEqual(first.returncode, 0, first.stderr + first.stdout)
        second = delegate("send", "alpha", "next instruction")
        self.assertEqual(second.returncode, 0, second.stderr + second.stdout)
        self.assertIn("next instruction", second.stdout)
        self.assertEqual(delegate("close", "alpha").returncode, 0)
        self.settled(desired="closed")
        self.assertEqual(delegate("resume", "alpha").returncode, 0)
        self.assertEqual(delegate("send", "alpha", "after resume").returncode, 0)
        agent = Broker(self.config).agent("alpha")
        env["ALAMODE_COORD_TOKEN"] = agent["child_token"]
        refused = delegate("--name", "forbidden", "spawn")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("Child capability", refused.stderr)

    def serve_forge(self, stub):
        fixture = self.root / "forge-stub"
        fixture.write_text(f"#!{sys.executable}\n{stub}")
        fixture.chmod(0o700)
        self.broker.terminate()
        self.broker.wait()
        self.config.update(with_forge=True, forge_bin=str(fixture), memory_budget_gib=4)
        self.config["policy"].update(forge=True, forge_sizes=["small"])
        atomic_json(self.directory / "broker.json", self.config)
        self.broker = self.launch("--serve", self.directory / "broker.json")
        wait_socket(self.config["socket"], self.config["token"], self.broker)

    def test_forge_adapter_budget_and_changed_lease(self):
        self.serve_forge(f"""
from pathlib import Path
import os,sys
root=Path({str(self.root)!r})
label=root/'forge-label'
operation=sys.argv[1]
if operation=='claim':
 label.write_text(sys.argv[2]);print('1')
elif not label.exists() or label.read_text()!=os.environ.get('FORGE_LEASE_LABEL'):
 print('forge lease changed',file=sys.stderr);sys.exit(1)
elif operation=='release':
 label.unlink();(root/'forge-removed').touch()
""")
        first = self.call("spawn", agent="alpha", task="hi", size="small")
        self.assertNotEqual(first.get("receipt"), "failed", first)
        self.settled()
        no_room = self.call("spawn", agent="beta", task="hi", size="small")
        self.assertEqual(no_room["receipt"], "failed")
        self.assertIn("budget", no_room["error"])
        self.call("forge_boot", agent="alpha")
        (self.root / "forge-label").write_text("new owner")
        refused = self.call("teardown", agent="alpha")
        self.assertEqual(refused["receipt"], "failed")
        self.assertIn("lease changed", refused["error"])
        self.assertFalse((self.root / "forge-removed").exists())
        self.assertIn(
            "lease changed", self.call("status", agent="alpha")["forge"]["error"]
        )

    def test_failed_forge_claim_holds_no_memory(self):
        self.serve_forge(f"""
from pathlib import Path
import sys
refused=Path({str(self.root)!r})/'forge-refused'
if not refused.exists():
 refused.touch();print('no forge instance 1-15 is free',file=sys.stderr);sys.exit(1)
if sys.argv[1]=='claim':
 print('1')
""")
        failed = self.call("spawn", agent="alpha", task="hi", size="small")
        self.assertEqual(failed["receipt"], "failed")
        self.assertIn("no forge instance", failed["error"])
        refused = self.call("forge_boot", agent="alpha")
        self.assertIn("Tear the agent down", refused["error"])
        retried = self.call("spawn", agent="beta", task="hi", size="small")
        self.assertNotEqual(retried.get("receipt"), "failed", retried)

    def test_failed_forge_init_keeps_its_lease_and_never_boots(self):
        self.serve_forge(f"""
from pathlib import Path
import sys
with (Path({str(self.root)!r})/'forge-log').open('a') as log:
 log.write(sys.argv[1]+'\\n')
if sys.argv[1]=='claim':
 print('1')
elif sys.argv[1]=='init':
 print('limactl create failed',file=sys.stderr);sys.exit(1)
""")
        failed = self.call("spawn", agent="alpha", task="hi", size="small")
        self.assertIn("limactl create failed", failed["error"])
        refused = self.call("forge_boot", agent="alpha")
        self.assertEqual(refused.get("receipt"), "failed", refused)
        self.assertIn("Tear the agent down", refused["error"])
        self.assertEqual(
            (self.root / "forge-log").read_text().split(), ["claim", "init"]
        )
        no_room = self.call("spawn", agent="beta", task="hi", size="small")
        self.assertIn("budget", no_room["error"])

    def test_resume_grants_forge_only_while_the_lease_is_live(self):
        self.serve_forge("""
import sys
if sys.argv[1]=='claim':
 print('1')
""")

        def resumed(name):
            self.settled(name, "closed")
            self.call("resume", agent=name)
            self.settled(name)
            manifest = json.loads(
                Path(Broker(self.config).agent(name)["manifest"]).read_text()
            )
            return "forge" in manifest.get("resources", {})

        self.call("spawn", agent="alpha", task="hi", size="small")
        self.settled()
        self.call("close", agent="alpha")
        self.assertTrue(resumed("alpha"))
        self.call("teardown", agent="alpha")
        self.assertFalse(resumed("alpha"))
        self.call("spawn", agent="beta", task="hi", size="small")
        self.settled("beta")
        pool = Store(Path(self.config["pool"]) / "forge.sqlite")
        with pool.db:
            pool.db.execute(
                "DELETE FROM state WHERE name=?",
                (Broker(self.config).agent("beta")["forge"]["label"],),
            )
        self.call("close", agent="beta")
        self.assertFalse(resumed("beta"))

    def test_teardown_releases_a_lost_agents_lease(self):
        self.serve_forge(f"""
from pathlib import Path
import sys
if sys.argv[1]=='claim':
 print('1')
elif sys.argv[1]=='release':
 (Path({str(self.root)!r})/'forge-removed').touch()
""")
        self.call("spawn", agent="alpha", task="hi", size="small")
        self.settled()
        Path(Broker(self.config).agent("alpha")["socket"]).unlink()
        self.settled(desired="lost")
        refused = self.call("teardown", agent="alpha")
        self.assertIn("still owns", refused["error"])
        self.assertFalse((self.root / "forge-removed").exists())
        directory = self.directory / "agents/alpha"
        os.kill(int((directory / "supervisor.pid").read_text()), signal.SIGKILL)
        deadline = time.monotonic() + 5
        while (ownership := lock_file(directory / "supervisor.lock")) is None:
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.02)
        ownership.close()
        released = self.call("teardown", agent="alpha")
        self.assertNotEqual(released.get("receipt"), "failed", released)
        self.assertEqual(released["forge"]["state"], "released")
        self.assertTrue((self.root / "forge-removed").exists())

    def test_teardown_releases_a_lease_whose_claim_failed(self):
        self.serve_forge(f"""
from pathlib import Path
import os,sys
root=Path({str(self.root)!r})
label=root/'forge-label'
if sys.argv[1]=='claim':
 if not (root/'forge-claimed').exists():
  (root/'forge-claimed').touch();label.write_text(sys.argv[2])
 print('killed at the timeout',file=sys.stderr);sys.exit(1)
if sys.argv[1]=='which' and label.exists() and label.read_text()==sys.argv[2]:
 print('1')
if sys.argv[1]=='release':
 assert os.environ['FORGE_INSTANCE']=='1'
 assert label.read_text()==os.environ['FORGE_LEASE_LABEL']
 label.unlink()
""")
        for name in ("alpha", "beta"):
            failed = self.call("spawn", agent=name, task="hi", size="small")
            self.assertIn("killed at the timeout", failed["error"])
        alpha = self.call("teardown", agent="alpha")
        self.assertNotEqual(alpha.get("receipt"), "failed", alpha)
        self.assertEqual(alpha["forge"]["state"], "released")
        self.assertEqual(alpha["forge"]["instance"], 1)
        self.assertFalse((self.root / "forge-label").exists())
        beta = self.call("teardown", agent="beta")
        self.assertNotEqual(beta.get("receipt"), "failed", beta)
        self.assertEqual(beta["forge"]["state"], "released")
        self.assertNotIn("instance", beta["forge"])

    def test_child_export_admission_and_parent_inbox_symlink(self):
        first = self.call("spawn", agent="alpha", task="hi")
        self.settled()
        child = Path(first["workspace"])
        (child / "file").write_text("child commit\n")
        self.git(child, "add", "file")
        self.git(child, "commit", "-qm", "child work")
        tip = self.git(child, "rev-parse", "HEAD")
        bundle = child / "proposal.bundle"
        self.git(child, "bundle", "create", str(bundle), "HEAD")
        agent = Broker(self.config).agent("alpha")
        offered = request(
            self.config["socket"],
            agent["child_token"],
            {"op": "offer", "id": "offer", "bundle": str(bundle), "tip": tip},
        )
        self.assertEqual(offered["tip"], tip)
        admitted = self.call("admit", agent="alpha")
        parent = Path(self.config["manifest"]["workspace"]["workspace"])
        self.git(
            parent, "fetch", "--no-tags", admitted["bundle"], "HEAD:refs/alamode/test"
        )
        self.git(parent, "cherry-pick", admitted["base"] + ".." + admitted["tip"])
        self.assertEqual((parent / "file").read_text(), "child commit\n")
        self.assertEqual((self.source / "file").read_text(), "baseline\n")
        inbox = parent.parent / "runtime/inbox"
        shutil.rmtree(inbox)
        outside = self.root / "outside"
        outside.mkdir()
        inbox.symlink_to(outside, target_is_directory=True)
        refused = self.call("admit", agent="alpha")
        self.assertEqual(refused["receipt"], "failed")
        self.assertEqual(list(outside.iterdir()), [])

    @unittest.skipUnless(
        os.environ.get("ALAMODE_TEST_BIN"),
        "Set ALAMODE_TEST_BIN to run the real engine RPC fixture",
    )
    def test_real_engine_rpc_lifecycle(self):
        launcher = Path(self.config["launcher"])
        launcher.write_text(f"""#!{sys.executable}
import json,os,sys
from pathlib import Path
manifest=json.loads(Path(sys.argv[2]).read_text())
runtime=Path(manifest['workspace']['session_root'])/'runtime'
agent=runtime/'agent'
agent.mkdir(parents=True,exist_ok=True)
(runtime/'sessions').mkdir(exist_ok=True)
(agent/'settings.json').write_text(json.dumps({{'retry':{{'enabled':False}},'quietStartup':True,'shellPath':'/bin/sh'}}))
env={{k:v for k,v in os.environ.items() if k in ('PATH','HOME','TMPDIR','LANG','TERM')}}
env.update(PI_CODING_AGENT_DIR=str(agent),PI_TELEMETRY='0',PI_SKIP_VERSION_CHECK='1')
# The -- boundary belongs to alamode, not the engine: strip it before
# forwarding, exactly as the real runtime does when it builds the engine's
# argv from the post-boundary arguments.
args=[a for i,a in enumerate(sys.argv[3:]) if not (a=='--' and i==0)]
os.execve({os.environ["ALAMODE_TEST_BIN"]!r},[{os.environ["ALAMODE_TEST_BIN"]!r},'--no-approve','--model','synthetic/fixture','-e',{str(ROOT / "fixture-provider.ts")!r},*args],env)
""")
        first = self.call("spawn", agent="alpha", task="SLOW_FIXTURE")
        self.assertNotEqual(first.get("receipt"), "failed", first)
        self.broker.kill()
        self.broker.wait()
        self.broker = self.launch("--serve", self.directory / "broker.json")
        wait_socket(self.config["socket"], self.config["token"], self.broker)
        outcome = self.settled()["outcome"]
        self.assertEqual(outcome["state"], "success", outcome)
        self.call("send", agent="alpha", message="SLOW_FIXTURE again")
        self.call("send", agent="alpha", message="steering", mode="steer")
        self.call("send", agent="alpha", message="followup", mode="follow_up")
        outcome = self.settled()["outcome"]
        self.assertIn("followup", outcome["text"])
        self.call("send", agent="alpha", message="/fixture-question")
        pending = self.settled(desired="waiting_input")
        dialog = next(iter(pending["dialogs"]))
        self.call("answer", agent="alpha", dialog=dialog, value="answer")
        self.settled()
        self.call("send", agent="alpha", message="SLOW_FIXTURE cancel")
        self.call("send", agent="alpha", message="must not run", mode="follow_up")
        self.call("interrupt", agent="alpha")
        self.assertEqual(self.settled()["outcome"]["state"], "aborted")
        self.call("send", agent="alpha", message="FAIL_FIXTURE")
        self.assertEqual(self.settled()["outcome"]["state"], "error")
        self.call("teardown", agent="alpha")
        self.settled(desired="closed")
        self.call("resume", agent="alpha")
        self.call("send", agent="alpha", message="resumed")
        self.assertIn("resumed", self.settled()["outcome"]["text"])


if __name__ == "__main__":
    unittest.main()
