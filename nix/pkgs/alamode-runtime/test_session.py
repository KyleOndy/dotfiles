import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import pty
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import types
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch


MODULE = Path(
    os.environ.get("ALAMODE_SESSION_MODULE", Path(__file__).with_name("session.py"))
)
sys.path.insert(0, str(MODULE.parent.parent / "alamode-coordinator"))
spec = importlib.util.spec_from_file_location("alamode_runtime", MODULE)
session = importlib.util.module_from_spec(spec)
spec.loader.exec_module(session)
KEY = "synthetic-provider-key-never-in-child"


def configuration(root):
    return {
        "pi": os.environ.get("ALAMODE_TEST_BIN", "pi"),
        "node": os.environ.get("ALAMODE_NODE", "node"),
        "shell": os.environ.get("ALAMODE_BASH", "/bin/bash"),
        "path": os.environ["PATH"],
        "bundles": {"registry": {"domains": ["registry.example.invalid"]}},
        "domains": [],
        "readPaths": [],
        "writePaths": [],
        "piArgs": [],
        "env": {},
        "systemReadPaths": [
            "/nix",
            "/etc",
            "/private/etc",
            "/dev",
            "/System",
            "/bin",
            "/usr",
            "/private/var/select",
            "/private/var/db/timezone",
        ],
        "allowTrustd": False,
        "allowNix": False,
        "builder": "",
        "coordinatorDaemon": "",
        "seatsFile": "",
        "trustedProviders": [],
        "settingsFile": "",
        "runtimeSource": "",
        "gitName": "Synthetic alamode",
        "gitEmail": "synthetic@example.invalid",
        "resolvers": {},
        "resolverGates": {},
        "catalogFile": str(root / "catalog.json"),
        "relayModule": os.environ.get(
            "ALAMODE_RELAY_MODULE", str(MODULE.parent.parent / "alamode-relay/relay.py")
        ),
        "sandboxRunner": str(root / "sandbox.mjs"),
        "privateProviderHosts": ["127.0.0.1"],
    }


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="alamode-session-policy-")
        self.root = Path(self.temporary.name)
        self.config = configuration(self.root)
        self.work = self.root / "session"
        self.work.mkdir(mode=0o700)
        # prepare() validates the trusted layout before pi starts, so the
        # fixture workspace carries the directories a real one has.
        (self.work / "worktree").mkdir(mode=0o700)
        (self.work / ".bare").mkdir(mode=0o700)
        self.records = self.root / "control"
        self.records.mkdir(mode=0o700)
        options = session.parse([], self.config)
        self.manifest = {
            "id": "fixture",
            "policy": session.policy(options, self.config, self.root),
            "seats": {"ALAMODE_SESSION_MODEL": "fixture/probe"},
            "workspace": {
                "session_root": str(self.work),
                "record_root": str(self.records),
                "workspace": str(self.work / "worktree"),
                "common_dir": str(self.work / ".bare"),
                "root_identity": [self.work.stat().st_dev, self.work.stat().st_ino],
            },
        }

    def tearDown(self):
        self.temporary.cleanup()

    def test_authority_and_resume_admission(self):
        # The -- boundary is hard: nothing unknown may appear before it.
        for args in (
            ["--model", "fixture/probe"],
            ["do the fixture"],
            ["--resume-session", "fixture"],
            ["--allow-unknown"],
            ["--no-sandbox"],
            ["--resume"],
        ):
            with self.subTest(strict=args), self.assertRaises(session.SessionError):
                session.parse(args, self.config)
        # A grant request is detectable, so a coordinator attach can refuse
        # it wholesale and a resume can route it to regrant().
        for args in (
            ["--web"],
            ["--allow-registry"],
            ["--allow-trustd"],
            ["--allow-clipboard"],
            ["--allow-nix"],
            ["--allow-git-write"],
            ["--no-git-write"],
        ):
            with self.subTest(grants=args):
                options = session.parse(args, self.config)
                self.assertTrue(session.requested_grants(options, self.config))
                with self.assertRaises(session.SessionError):
                    session.refuse_grant_changes(options, self.config)
        self.assertFalse(
            session.requested_grants(session.parse([], self.config), self.config)
        )
        # Profiles expand into the same fields the flags set, so a resume
        # refuses them exactly like their spelled-out grants.
        self.config["profiles"] = {
            "work": {
                "domains": ["registry.example.invalid"],
                "readPaths": ["/approved"],
                "writePaths": [],
                "listenPorts": [3000],
                "trustd": True,
                "nix": False,
                "forge": False,
                "bundles": ["registry"],
            }
        }
        options = session.parse(["--profile", "work"], self.config)
        self.assertEqual(options.allow, ["registry.example.invalid"])
        self.assertEqual(options.allow_read, ["/approved"])
        self.assertEqual(options.listen, [3000])
        self.assertTrue(options.allow_trustd)
        self.assertTrue(options.bundle_registry)
        self.assertTrue(session.requested_grants(options, self.config))
        grants = session.policy(options, self.config, self.root)
        self.assertIn("registry.example.invalid", grants["domains"])
        self.assertEqual(grants["allow"], ["registry.example.invalid"])
        self.assertIn("registry", grants["grants"])
        with self.assertRaises(session.SessionError):
            session.parse(["--profile", "missing"], self.config)
        for path in (
            self.records,
            self.root,
            self.records / "nested",
            Path("/nix/var/nix/daemon-socket"),
        ):
            self.manifest["policy"]["read"] = [str(path)]
            with self.assertRaises(session.SessionError):
                session.validate_grants(self.manifest, self.records)

        self.manifest["policy"]["read"] = []
        for path in session.transport_directories(self.manifest):
            for value in (path, path.parent, path / "replacement.sock"):
                self.manifest["policy"]["write"] = [str(value)]
                with self.assertRaises(session.SessionError):
                    session.validate_grants(self.manifest, self.records)
        self.manifest["policy"]["write"] = []
        rules = session.sandbox_policy(
            self.config, self.manifest, self.work / "runtime", 0
        )
        for path in session.transport_directories(self.manifest):
            self.assertIn(str(path), rules["filesystem"]["denyWrite"])

    def test_regrant_replaces_grants_and_records_the_old_policy(self):
        self.config["bundles"]["paths"] = {"readPaths": ["/approved"]}
        launched = ["--web", "--allow-read", "/kept"]
        manifest = {
            **self.manifest,
            "grant_args": launched,
            "policy": session.policy(
                session.parse(launched, self.config), self.config, self.root
            ),
        }
        requested = ["--allow-read", "/kept", "--allow-paths", "--listen", "3000"]
        updated, changes = session.regrant(
            self.config, manifest, requested, self.root, self.records
        )
        # GRANTS replace the recorded ones: --web, not restated, is dropped.
        self.assertEqual(changes, ["-web", "+paths", "+read /approved", "+listen 3000"])
        self.assertFalse(updated["policy"]["web"])
        self.assertEqual(updated["grant_args"], requested)
        self.assertEqual(updated["regrants"][-1]["policy"], manifest["policy"])
        self.assertEqual(updated["regrants"][-1]["grant_args"], launched)
        self.assertNotIn("regrants", manifest)
        again, _ = session.regrant(
            self.config, updated, launched, self.root, self.records
        )
        self.assertEqual(
            [entry["grant_args"] for entry in again["regrants"]], [launched, requested]
        )

    def test_regrant_keeps_model_scope_and_coordinator_grants(self):
        self.config["trustedProviders"] = ["fixture"]
        manifest = {
            **self.manifest,
            "grant_args": [],
            "policy": {
                **self.manifest["policy"],
                "allowed_models": ["fixture/probe"],
                "catalog_scope": "digest",
            },
        }
        for args in (["--local"], ["--no-fixture"], ["--local-model", "fixture/x"]):
            with (
                self.subTest(args=args),
                self.assertRaisesRegex(session.SessionError, "stay as the session"),
            ):
                session.regrant(self.config, manifest, args, self.root, self.records)
        for key in ("coordinator_id", "coordinator"):
            with (
                self.subTest(key=key),
                self.assertRaisesRegex(session.SessionError, "new coordinator"),
            ):
                session.regrant(
                    self.config,
                    {**manifest, key: {"role": "main"}},
                    ["--web"],
                    self.root,
                    self.records,
                )
        # main() hands over the control directory resolved, as expand()
        # resolves grants.
        control = self.records.resolve()
        with self.assertRaisesRegex(session.SessionError, "overlaps trusted"):
            session.regrant(
                self.config,
                manifest,
                ["--allow-read", str(control)],
                self.root,
                control,
            )
        updated, _ = session.regrant(
            self.config, manifest, ["--web"], self.root, self.records
        )
        self.assertEqual(updated["policy"]["allowed_models"], ["fixture/probe"])
        self.assertEqual(updated["policy"]["catalog_scope"], "digest")

    def test_regrant_request_is_taken_once_and_never_followed(self):
        self.assertIsNone(session.take_regrant_request(self.manifest))
        request = self.work / session.REGRANT_REQUEST
        request.parent.mkdir(parents=True)
        request.write_text("--web --allow-read '/a b'\n")
        self.assertEqual(
            session.take_regrant_request(self.manifest),
            ["--web", "--allow-read", "/a b"],
        )
        self.assertFalse(request.exists())
        self.assertIsNone(session.take_regrant_request(self.manifest))
        # An emptied editor asks for the host defaults alone.
        request.write_text("\n")
        self.assertEqual(session.take_regrant_request(self.manifest), [])
        elsewhere = self.work / "elsewhere"
        elsewhere.write_text("--web\n")
        request.symlink_to(elsewhere)
        with self.assertRaises(OSError):
            session.take_regrant_request(self.manifest)
        self.assertFalse(request.is_symlink())
        self.assertTrue(elsewhere.exists())
        request.write_text("--allow-read 'unclosed\n")
        with self.assertRaisesRegex(session.SessionError, "unreadable"):
            session.take_regrant_request(self.manifest)

    def test_child_learns_its_grant_flags_and_where_to_ask_for_others(self):
        runtime = self.work / "runtime"
        manifest = {**self.manifest, "grant_args": ["--allow-read", "/a b"]}
        environment = session.child_environment(
            self.config, manifest, self.root, runtime
        )
        self.assertEqual(environment["ALAMODE_GRANT_ARGS"], "--allow-read '/a b'")
        self.assertEqual(
            environment["ALAMODE_REGRANT_REQUEST"],
            str(self.work / session.REGRANT_REQUEST),
        )
        self.assertNotIn("ALAMODE_REGRANTED", environment)
        environment = session.child_environment(
            self.config, {**manifest, "regranted": ["+web", "-nix"]}, self.root, runtime
        )
        self.assertEqual(environment["ALAMODE_REGRANTED"], "+web -nix")
        coordinated = {
            **manifest,
            "coordinator": {"socket": "s", "token": "t", "id": "c", "role": "main"},
        }
        environment = session.child_environment(
            self.config, coordinated, self.root, runtime
        )
        self.assertNotIn("ALAMODE_REGRANT_REQUEST", environment)

    def test_resume_regrants_and_relaunches_on_request(self):
        home = self.root / "home"
        control = session.directory(home / ".local/state/alamode")
        record = session.directory(session.directory(control / "records") / "fixture")
        config_path = (self.root / "configuration.json").resolve()
        config_path.write_text(json.dumps(self.config))
        manifest = {
            **self.manifest,
            "grant_args": [],
            "configuration": str(config_path),
        }
        (record / "manifest.json").write_text(json.dumps(manifest))
        runs = []

        def run(config, manifest, args, home):
            runs.append(manifest)
            if len(runs) == 1:
                path = (
                    Path(manifest["workspace"]["session_root"])
                    / session.REGRANT_REQUEST
                )
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("--allow-registry\n")
            return 0

        with (
            patch.dict(os.environ, {"HOME": str(home)}),
            patch.object(session, "run", run),
            patch.object(session, "land"),
            patch.object(session, "pin_store_roots"),
            patch.object(session, "confirm_regrant", return_value=True) as confirm,
            redirect_stderr(io.StringIO()),
        ):
            with self.assertRaisesRegex(session.SessionError, "Name the session"):
                session.main([str(config_path), "alamode", "resume", "--web"])
            self.assertEqual(
                session.main(
                    [str(config_path), "alamode", "resume", "fixture", "--web"]
                ),
                0,
            )
        self.assertEqual([entry["policy"]["web"] for entry in runs], [True, False])
        self.assertEqual(runs[0]["regranted"], ["+web"])
        self.assertEqual(runs[1]["regranted"], ["-web", "+registry"])
        self.assertEqual(confirm.call_args.args[1], ["--allow-registry"])
        saved = json.loads((record / "manifest.json").read_text())
        self.assertEqual(saved["grant_args"], ["--allow-registry"])
        self.assertNotIn("regranted", saved)
        self.assertEqual(
            [entry["grant_args"] for entry in saved["regrants"]], [[], ["--web"]]
        )

    def test_confirm_regrant_reads_the_answer_from_the_terminal(self):
        pid, terminal = pty.fork()
        if pid == 0:
            accepted = False
            try:
                accepted = session.confirm_regrant(
                    {"id": "fixture"}, ["--web"], ["+web"]
                )
            finally:
                os._exit(0 if accepted else 1)
        # Read to the end: the child cannot finish exiting while the
        # terminal holds output nobody has read.
        output = b""
        answered = False
        while True:
            try:
                chunk = os.read(terminal, 1024)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
            if not answered and b"[y/N] " in output:
                os.write(terminal, b"y\n")
                answered = True
        _, status = os.waitpid(pid, 0)
        os.close(terminal)
        self.assertIn(b"Relaunch with these grants? [y/N] ", output)
        self.assertEqual(os.waitstatus_to_exitcode(status), 0)

    def test_information_does_not_admit_source_or_credentials(self):
        executable = self.root / "fake-pi"
        evidence = self.root / "information.json"
        executable.write_text(
            f"#!{sys.executable}\nimport json, os, pathlib, sys\npathlib.Path({str(evidence)!r}).write_text(json.dumps({{'args':sys.argv[1:],'env':dict(os.environ),'cwd':os.getcwd()}}))\n"
        )
        executable.chmod(0o700)
        config = self.root / "configuration.json"
        config.write_text(json.dumps({**self.config, "pi": str(executable)}))
        with (
            patch.dict(
                os.environ,
                {"NODE_OPTIONS": "untrusted startup", "PROVIDER_API_KEY": KEY},
            ),
            patch.object(
                session.workspace,
                "create",
                side_effect=AssertionError("Information must not snapshot files"),
            ),
        ):
            # --version passes through to the engine under the hardened
            # information environment, admitting no source or credentials.
            with redirect_stdout(io.StringIO()):
                self.assertEqual(session.main([str(config), "alamode", "--version"]), 0)
            result = json.loads(evidence.read_text())
            self.assertIn("--version", result["args"])
            self.assertIn("--no-extensions", result["args"])
            self.assertNotIn("NODE_OPTIONS", result["env"])
            self.assertNotIn("PROVIDER_API_KEY", result["env"])
            self.assertNotEqual(result["cwd"], str(self.root))
            # --help is alamode's own: the engine is never invoked.
            evidence.unlink()
            output = io.StringIO()
            with redirect_stdout(output):
                self.assertEqual(session.main([str(config), "alamode", "--help"]), 0)
            self.assertIn("alamode resume", output.getvalue())
            self.assertIn("coord", output.getvalue())
            self.assertFalse(evidence.exists())

    def test_replaced_workspace_is_rejected_before_execution(self):
        self.work.rename(self.root / "old-session")
        self.work.mkdir(mode=0o700)
        with self.assertRaisesRegex(session.SessionError, "root was replaced"):
            session.execute(
                self.config, self.manifest, ["false"], {}, self.work / "runtime"
            )

    def test_runner_keeps_the_session_tmpdir(self):
        runtime = self.work / "runtime"
        with patch.object(session.subprocess, "Popen") as popen:
            popen.return_value.wait.return_value = 0
            popen.return_value.poll.return_value = 0
            session.execute(
                self.config,
                self.manifest,
                ["true"],
                {"PATH": "/usr/bin", "TMPDIR": str(runtime / "tmp")},
                runtime,
            )
        self.assertEqual(
            popen.call_args.kwargs["env"]["CLAUDE_CODE_TMPDIR"], str(runtime / "tmp")
        )

    def fixture_relay(self):
        relay_source = self.root / "relay-fixture.py"
        relay_source.write_text(
            "class Relay:\n"
            "    catalog = {'providers': {}}\n"
            "    tool_env = {}\n"
            "    port = 0\n"
            "    def __enter__(self):\n"
            "        return self\n"
            "    def __exit__(self, *exc):\n"
            "        return False\n"
            "def start_relay(*args, **kwargs):\n"
            "    return Relay()\n"
        )
        self.config["relayModule"] = str(relay_source)
        Path(self.config["catalogFile"]).write_text(
            json.dumps(
                {
                    "providers": {
                        "fixture": {
                            "api": "openai-completions",
                            "baseUrl": "https://provider.example.invalid/v1",
                            "apiKey": "fixture-key",
                            "models": [{"id": "probe", "maxTokens": 128}],
                        }
                    }
                }
            )
        )

    def test_run_hands_the_build_client_to_the_child_under_its_own_name(self):
        # bin/nix reads ALAMODE_BUILD_CLIENT at its first read, so a child
        # handed the build client under any other name has a nix that dies at
        # the shim. The producer and consumer are pinned to one name here,
        # where no sandbox is needed to see it.
        self.config["buildClient"] = str(self.root / "tools" / "nix")
        self.config["builderModule"] = str(self.root / "builder-module.py")
        self.fixture_relay()
        manifest = {
            **self.manifest,
            "policy": {**self.manifest["policy"], "nix": True},
            "builder": {"record_root": str(self.root / "builder")},
        }

        class FakeBuildService:
            client = {"socket": "fixture-socket"}
            socket = "fixture-socket"

            def __init__(self, *args, **kwargs):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        build_service = types.ModuleType("build_service")
        build_service.BuildService = FakeBuildService
        captured = {}

        def record(config, manifest, arguments, environment, runtime, relay_port=0):
            captured.update(environment)
            return 0

        with (
            patch.dict(sys.modules, {"build_service": build_service}),
            patch.object(session, "execute", record),
        ):
            self.assertEqual(session.run(self.config, manifest, [], self.root), 0)
        # The trusted side wrote runtime/build.json; the child gets its path
        # under the one name the shim reads.
        self.assertEqual(
            captured["ALAMODE_BUILD_CLIENT"],
            str(self.work / "runtime" / "build.json"),
        )

    def test_nix_is_offered_only_with_a_builder_or_session_daemon(self):
        runtime = self.work / "runtime"
        self.config["bundles"]["flake"] = {"domains": [], "nix": True}

        def available():
            environment = session.child_environment(
                self.config, self.manifest, self.root, runtime
            )
            return environment["ALAMODE_AVAILABLE_GRANTS"].split(",")

        def grant():
            return session.policy(
                session.parse(["--allow-nix"], self.config), self.config, self.root
            )

        self.assertNotIn("nix", available())
        self.assertNotIn("flake", available())
        self.assertIn("registry", available())
        with self.assertRaisesRegex(session.SessionError, "Host daemon access"):
            grant()
        for key, value in (
            ("builder", str(self.root / "builder.json")),
            ("nixDaemonSocket", str(self.root / "daemon.sock")),
        ):
            with self.subTest(key=key), patch.dict(self.config, {key: value}):
                self.assertIn("nix", available())
                self.assertIn("flake", available())
                self.assertTrue(grant()["nix"])

    def session_daemon(self):
        # A host whose --allow-nix is the session daemon. The client plays
        # each canary from the (stderr, exit code) pairs in CANARY_OUTCOMES,
        # unless asked to substitute, which plays an unreachable cache.
        client = self.root / "client"
        client.mkdir()
        (client / "nix").write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "name = sys.argv[sys.argv.index('--file') + 2]\n"
            "error, code = json.loads(os.environ['CANARY_OUTCOMES'])[name]\n"
            "if 'substitute' not in sys.argv:\n"
            "    error, code = \"error: unable to download '.narinfo'\\n\", 1\n"
            "sys.stderr.write(error)\n"
            "sys.exit(code)\n"
        )
        (client / "nix").chmod(0o755)
        daemon = socket.socket(socket.AF_UNIX)
        self.addCleanup(daemon.close)
        daemon.bind(str(self.root / "daemon.sock"))
        self.config.update(
            nixDaemonSocket=str(self.root / "daemon.sock"),
            nixDaemonLabel="org.example.session-nix",
            nixClient=str(client),
            nixClientConf=str(self.root / "conf"),
            nixCanary=str(self.root / "canary.nix"),
        )

    def canary(self, outcomes):
        session.nix_canary(
            self.config,
            self.manifest,
            {"PATH": os.environ["PATH"], "CANARY_OUTCOMES": json.dumps(outcomes)},
        )

    def test_nix_canary_refuses_a_daemon_that_would_give_a_build_network(self):
        self.session_daemon()
        hook = "error: pre-build hook '/nix/store/x-hook' failed with exit code 1\n"
        healthy = {
            "fod": [hook, 1],
            "fetchurl": [hook, 1],
            "localnet": [hook, 1],
            "net": ["error: builder failed with exit code 7\n", 1],
            "large": ["", 0],
        }
        told = io.StringIO()
        with redirect_stderr(told):
            self.canary(healthy)
        self.assertEqual(told.getvalue(), "")
        for name, outcome in (
            ("fod", ["", 0]),
            ("localnet", ["", 0]),
            # It ran: the hash check comes after the fetch went out.
            ("fetchurl", ["error: hash mismatch in fixed-output derivation\n", 1]),
            # Refused by the hook, net never tested the sandbox.
            ("net", [hook, 1]),
            ("net", ["", 0]),
            ("large", ["error: builder failed with exit code 1\n", 1]),
        ):
            told = io.StringIO()
            with (
                self.subTest(name=name, outcome=outcome),
                redirect_stderr(told),
                self.assertRaisesRegex(session.SessionError, "failed its canary"),
            ):
                self.canary({**healthy, name: outcome})
            self.assertIn(f"canary ({name})", told.getvalue())
            log = (self.records / "nix-canary.log").read_text()
            self.assertIn(f"== {name}: exit {outcome[1]}", log)

    def test_nix_canary_says_how_to_start_a_daemon_that_is_not_answering(self):
        self.session_daemon()
        refused = "error: cannot connect to socket at '/x': Connection refused\n"
        outcomes = {
            name: [refused, 1] for name in (*session.NIX_CANARY_REFUSED, "net", "large")
        }
        for stale in (False, True):
            if stale:
                Path(self.config["nixDaemonSocket"]).unlink()
            told = io.StringIO()
            with (
                self.subTest(stale=stale),
                redirect_stderr(told),
                self.assertRaisesRegex(session.SessionError, "not running"),
            ):
                self.canary(outcomes)
            self.assertIn(
                "launchctl kickstart system/org.example.session-nix", told.getvalue()
            )

    def test_session_daemon_nix_hands_the_child_a_client_and_one_socket(self):
        self.session_daemon()
        self.fixture_relay()
        manifest = {
            **self.manifest,
            "policy": {**self.manifest["policy"], "nix": True},
        }
        canaries = []
        captured = {}

        def record(config, manifest, arguments, environment, runtime, relay_port=0):
            captured.update(environment)
            return 0

        with (
            patch.object(session, "nix_canary", lambda *args: canaries.append(args)),
            patch.object(session, "execute", record),
        ):
            self.assertEqual(session.run(self.config, manifest, [], self.root), 0)
        self.assertEqual(len(canaries), 1)
        socket_path = self.config["nixDaemonSocket"]
        self.assertEqual(captured["NIX_REMOTE"], "unix://" + socket_path)
        self.assertEqual(captured["NIX_CONF_DIR"], self.config["nixClientConf"])
        self.assertTrue(captured["PATH"].startswith(self.config["nixClient"] + ":"))
        self.assertNotIn("ALAMODE_BUILD_CLIENT", captured)
        runtime = self.work / "runtime"
        granted = session.sandbox_policy(self.config, manifest, runtime, 0)
        self.assertIn(socket_path, granted["network"]["allowUnixSockets"])
        plain = session.sandbox_policy(self.config, self.manifest, runtime, 0)
        self.assertNotIn(socket_path, plain["network"]["allowUnixSockets"])

    def test_local_refuses_the_network_and_drops_host_defaults(self):
        self.config["domains"] = ["default.example.invalid"]
        self.config["allowTrustd"] = True
        self.config["bundles"]["paths"] = {"readPaths": ["/approved"]}
        for args in (
            ["--web"],
            ["--allow", "host.example.invalid"],
            ["--allow-registry"],
            ["--allow-nix"],
            ["--allow-forge"],
            ["--allow-trustd"],
            ["--allow-clipboard"],
        ):
            with (
                self.subTest(args=args),
                self.assertRaisesRegex(session.SessionError, "--local refuses"),
            ):
                session.policy(
                    session.parse(["--local", *args], self.config),
                    self.config,
                    self.root,
                )
        options = session.parse(
            ["--local", "--allow-paths", "--listen", "3000"], self.config
        )
        self.assertTrue(session.requested_grants(options, self.config))
        grants = session.policy(options, self.config, self.root)
        self.assertEqual(grants["domains"], ["127.0.0.1:3000"])
        self.assertFalse(grants["trustd"])
        self.assertIn("/approved", grants["read"])

    def test_local_scope_admits_only_loopback_models(self):
        catalog = {
            "providers": {
                "cloud": {
                    "api": "openai-completions",
                    "baseUrl": "https://provider.example.invalid/v1",
                    "models": [{"id": "far"}, {"id": "tunnel"}],
                    "modelOverrides": {"tunnel": {"baseUrl": "http://localhost:9/v1"}},
                },
                "loop": {
                    "api": "openai-completions",
                    "baseUrl": "http://127.0.0.1:8080/v1",
                    "models": [{"id": "near"}],
                },
                "lookalike": {
                    "api": "openai-completions",
                    "baseUrl": "https://127.0.0.1.example.invalid/v1",
                    "models": [{"id": "far"}],
                },
            }
        }
        models, digest = session.catalog_scope(catalog, self.config, local=True)
        self.assertEqual(models, ["cloud/tunnel", "loop/near"])
        self.manifest["policy"].update(
            local=True, allowed_models=models, catalog_scope=digest
        )
        Path(self.config["catalogFile"]).write_text(json.dumps(catalog))
        _, auth = session.credentials(self.config, self.manifest, self.root)
        self.assertEqual(sorted(auth), ["cloud", "loop"])
        kept, dropped = session.scoped_seats(
            {
                "ALAMODE_SESSION_MODEL": "loop/near:off",
                "ALAMODE_ADVISOR_MODEL": "cloud/far",
                "ALAMODE_SPAWN_MODEL": "lookalike/far",
            },
            self.manifest["policy"],
        )
        self.assertEqual(kept, {"ALAMODE_SESSION_MODEL": "loop/near:off"})
        self.assertEqual(dropped, ["ALAMODE_ADVISOR_MODEL", "ALAMODE_SPAWN_MODEL"])
        self.config["trustedProviders"] = ["cloud", "loop", "lookalike"]
        environment = session.child_environment(
            self.config, self.manifest, self.root, self.work / "runtime"
        )
        self.assertEqual(environment["ALAMODE_TRUSTED_PROVIDERS"], "cloud,loop")

    def test_local_model_admits_an_uncatalogued_loopback_model(self):
        catalog = {
            "providers": {
                "cloud": {
                    "api": "openai-completions",
                    "baseUrl": "https://provider.example.invalid/v1",
                    "models": [{"id": "far"}, {"id": "tunnel"}],
                    "modelOverrides": {"tunnel": {"baseUrl": "http://localhost:9/v1"}},
                },
                "loop": {
                    "api": "openai-completions",
                    "baseUrl": "http://127.0.0.1:8080/v1",
                    "models": [
                        {"id": "near", "name": "near (local)", "contextWindow": 4096}
                    ],
                },
            }
        }
        self.config["trustedProviders"] = ["cloud", "loop"]
        for value in ("cloud/new", "loop", "missing/new", "loop/"):
            options = session.parse(["--local-model", value], self.config)
            grants = session.policy(options, self.config, self.root)
            with self.assertRaises(session.SessionError):
                session.admit_local_models(
                    json.loads(json.dumps(catalog)),
                    self.config,
                    grants["local_models"],
                )
        options = session.parse(
            ["--local-model", "loop/fresh", "--local-model", "loop/near"],
            self.config,
        )
        self.assertTrue(session.requested_grants(options, self.config))
        with self.assertRaises(session.SessionError):
            session.refuse_grant_changes(options, self.config)
        grants = session.policy(options, self.config, self.root)
        self.assertEqual(grants["local_models"], ["loop/fresh", "loop/near"])
        models, digest = session.catalog_scope(
            session.admit_local_models(
                json.loads(json.dumps(catalog)), self.config, grants["local_models"]
            ),
            self.config,
        )
        self.assertEqual(
            models, ["cloud/far", "cloud/tunnel", "loop/near", "loop/fresh"]
        )
        self.manifest["policy"].update(
            local_models=grants["local_models"],
            allowed_models=models,
            catalog_scope=digest,
        )
        Path(self.config["catalogFile"]).write_text(json.dumps(catalog))
        relay_catalog, _ = session.credentials(self.config, self.manifest, self.root)
        self.assertEqual(
            relay_catalog["providers"]["loop"]["models"][-1],
            {"id": "fresh", "name": "fresh", "contextWindow": 4096},
        )
        # A model borrowed from a cloud provider's loopback override is
        # loopback too, and lands on that override's endpoint.
        borrowed = session.admit_local_models(
            {
                "providers": {
                    "cloud": {
                        **catalog["providers"]["cloud"],
                        "models": [{"id": "tunnel"}],
                    }
                }
            },
            self.config,
            ["cloud/fresh"],
        )
        self.assertEqual(
            borrowed["providers"]["cloud"]["models"][-1]["baseUrl"],
            "http://localhost:9/v1",
        )
        # credentials() reapplies the grant from the manifest, and the
        # admitted digest covers the granted model, so a manifest missing the
        # grant fails the scope check.
        del self.manifest["policy"]["local_models"]
        with self.assertRaises(session.SessionError):
            session.credentials(self.config, self.manifest, self.root)

    def test_no_provider_excludes_it_and_every_model_on_its_endpoints(self):
        catalog = {
            "providers": {
                "cloud": {
                    "api": "openai-completions",
                    "baseUrl": "https://provider.example.invalid/v1",
                    "apiKey": "$CLOUD_KEY_NEVER_RESOLVED",
                    "models": [{"id": "far"}, {"id": "tunnel"}],
                    "modelOverrides": {"tunnel": {"baseUrl": "http://localhost:9/v1"}},
                },
                "alias": {
                    "api": "openai-completions",
                    "baseUrl": "https://PROVIDER.example.invalid:443/v2",
                    "apiKey": "$ALIAS_KEY_NEVER_RESOLVED",
                    "models": [{"id": "same"}],
                },
                "other": {
                    "api": "openai-completions",
                    "baseUrl": "https://other.example.invalid/v1",
                    "models": [{"id": "kept"}, {"id": "tunnelled"}],
                    "modelOverrides": {
                        "tunnelled": {"baseUrl": "http://localhost:9/v1"}
                    },
                },
                "loop": {
                    "api": "openai-completions",
                    "baseUrl": "http://127.0.0.1:8080/v1",
                    "models": [{"id": "near"}],
                },
            }
        }
        self.config["trustedProviders"] = ["cloud", "alias", "other", "loop"]
        with self.assertRaises(session.SessionError):
            session.parse(["--no-unknown"], self.config)
        options = session.parse(["--no-cloud"], self.config)
        self.assertTrue(session.requested_grants(options, self.config))
        with self.assertRaises(session.SessionError):
            session.refuse_grant_changes(options, self.config)
        grants = session.policy(options, self.config, self.root)
        self.assertEqual(grants["excluded_providers"], ["cloud"])
        models, digest = session.catalog_scope(
            catalog, self.config, excluded=grants["excluded_providers"]
        )
        self.assertEqual(models, ["other/kept", "loop/near"])
        self.manifest["policy"].update(
            excluded_providers=["cloud"], allowed_models=models, catalog_scope=digest
        )
        Path(self.config["catalogFile"]).write_text(json.dumps(catalog))
        relay_catalog, auth = session.credentials(self.config, self.manifest, self.root)
        self.assertEqual(sorted(relay_catalog["providers"]), ["loop", "other"])
        self.assertEqual(sorted(auth), ["loop", "other"])
        kept, dropped = session.scoped_seats(
            {
                "ALAMODE_SESSION_MODEL": "cloud/far:high",
                "ALAMODE_ADVISOR_MODEL": "alias/same",
                "ALAMODE_SPAWN_MODEL": "other/kept:high",
            },
            self.manifest["policy"],
        )
        self.assertEqual(kept, {"ALAMODE_SPAWN_MODEL": "other/kept:high"})
        self.assertEqual(dropped, ["ALAMODE_ADVISOR_MODEL", "ALAMODE_SESSION_MODEL"])
        environment = session.child_environment(
            self.config, self.manifest, self.root, self.work / "runtime"
        )
        self.assertEqual(environment["ALAMODE_TRUSTED_PROVIDERS"], "other,loop")

    def test_catalog_scope_tracks_effective_override_routes(self):
        catalog = {
            "providers": {
                "fixture": {
                    "api": "openai-completions",
                    "baseUrl": "https://provider.example.invalid/v1",
                    "models": [
                        {"id": "probe", "baseUrl": "https://model.example.invalid/v1"}
                    ],
                    "modelOverrides": {
                        "probe": {"baseUrl": "https://override.example.invalid/v1"}
                    },
                }
            }
        }
        models, before = session.catalog_scope(catalog, self.config)
        self.assertEqual(models, ["fixture/probe"])
        catalog["providers"]["fixture"]["modelOverrides"]["probe"]["baseUrl"] = (
            "https://changed.example.invalid/v1"
        )
        self.assertNotEqual(before, session.catalog_scope(catalog, self.config)[1])
        self.manifest["policy"]["catalog_scope"] = before
        Path(self.config["catalogFile"]).write_text(json.dumps(catalog))
        with self.assertRaisesRegex(
            session.SessionError, "endpoints or model scope changed"
        ):
            session.credentials(self.config, self.manifest, self.root)

    def test_export_admits_repeated_self_contained_bundles(self):
        source = self.root / "source"
        source.mkdir()
        git_env = session.workspace._environment()

        def git(where, *args):
            return subprocess.run(
                [session.workspace.GIT, "-C", str(where), *args],
                env=git_env,
                check=True,
                capture_output=True,
                text=True,
            )

        git(source, "init", "-q", "-b", "main")
        (source / "initial").write_text("initial")
        git(source, "add", ".")
        git(
            source,
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "Fixture",
        )
        source_head = git(source, "rev-parse", "HEAD").stdout.strip()
        (source / "initial").write_text("authorized dirty snapshot")
        metadata = session.workspace.create(
            source,
            self.root / "export-session",
            "fixture",
            record_root=self.records / "export-fixture",
        )
        # A rebuilt runtime is the normal reason an old session needs
        # exporting, so the manifest names a configuration path that never
        # exists: extraction must not consult the runtime that recorded it.
        manifest = {
            **self.manifest,
            "workspace": metadata,
            "configuration": str(self.root / "a-rebuilt-runtime.json"),
        }
        work = Path(metadata["workspace"])
        (work / "agent").write_text("agent change")
        git(work, "add", "agent")
        git(
            work,
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "Agent fixture",
        )
        tip = git(work, "rev-parse", "HEAD").stdout.strip()
        canary = self.root / "outside-git-executed"
        with (Path(metadata["common_dir"]) / "config").open("a") as stream:
            stream.write(f"\n[core]\n fsmonitor = touch {canary}\n")

        original_git = session.workspace._git

        def trusted_git(directory, *args, **kwargs):
            # Sealing and admission run trusted git only on fresh repos under
            # the record root; the session's own Git storage is read by the
            # no-symlink ref reader and never executed. The neutralizations
            # travel inside _git itself; the fsmonitor canary below is the
            # behavioral proof no session config is ever honored.
            self.assertNotIn(Path(metadata["session_root"]), Path(directory).parents)
            return original_git(directory, *args, **kwargs)

        exports = []
        with patch.object(session.workspace, "_git", side_effect=trusted_git):
            for _ in range(2):
                output, steps = io.StringIO(), io.StringIO()
                with redirect_stdout(output), redirect_stderr(steps):
                    self.assertEqual(session.export_session(manifest), 0)
                exports.append(json.loads(output.getvalue()))
        # The JSON stays on stdout; the human's next commands go to stderr.
        self.assertIn(f"{exports[1]['ref']}:alamode-fixture", steps.getvalue())
        self.assertIn("&& git adopt", steps.getvalue())
        self.assertNotEqual(exports[0]["bundle"], exports[1]["bundle"])
        # Context files ride admission as a recorded warning, not a refusal.
        self.assertEqual(exports[0]["context_files"], [])
        self.assertEqual(exports[1]["context_files"], [])
        empty = self.root / "receiver"
        empty.mkdir()
        git(empty, "init", "-q", "--bare")
        git(
            empty,
            "fetch",
            exports[0]["bundle"],
            exports[0]["ref"] + ":refs/heads/result",
        )
        self.assertEqual(
            git(empty, "rev-parse", "refs/heads/result").stdout.strip(), tip
        )
        self.assertEqual(git(source, "rev-parse", "HEAD").stdout.strip(), source_head)
        self.assertEqual((source / "initial").read_text(), "authorized dirty snapshot")
        self.assertFalse(canary.exists())

    def sealed_session(self, name, dirty=False):
        """A session workspace with one agent commit on top of its snapshot."""
        source = self.root / (name + "-source")
        source.mkdir()
        git_env = session.workspace._environment()

        def git(where, *args):
            return subprocess.run(
                [session.workspace.GIT, "-C", str(where), *args],
                env=git_env,
                check=True,
                capture_output=True,
                text=True,
            )

        git(source, "init", "-q", "-b", "main")
        (source / "file").write_text("base\n")
        git(source, "add", ".")
        git(
            source,
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "Base",
        )
        if dirty:
            (source / "wip").write_text("human wip\n")
        metadata = session.workspace.create(
            source,
            self.root / (name + "-session"),
            "fixture",
            record_root=self.records / (name + "-records"),
        )
        work = Path(metadata["workspace"])
        (work / "file").write_text("agent change\n")
        git(work, "add", ".")
        git(
            work,
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "Agent change",
        )
        manifest = {
            **self.manifest,
            "workspace": metadata,
            "configuration": str(self.root / "a-rebuilt-runtime.json"),
        }
        return manifest, git(work, "rev-parse", "HEAD").stdout.strip()

    def test_resume_names_the_recorded_runtime_and_export_does_not(self):
        manifest = {
            **self.manifest,
            "id": "fixture-runtime",
            "configuration": str(self.root / "old-runtime.json"),
        }
        # A matching build re-admits the session without comment.
        session.require_recorded_runtime(manifest, str(self.root / "old-runtime.json"))
        with self.assertRaisesRegex(
            session.SessionError, "different runtime"
        ) as raised:
            session.require_recorded_runtime(
                manifest, str(self.root / "new-runtime.json")
            )
        # The refusal names the recorded build and the export that still
        # works, so the dead end carries its own way out.
        message = str(raised.exception)
        self.assertIn("old-runtime.json", message)
        self.assertIn("sessions export fixture-runtime", message)

    def test_export_refuses_when_nothing_is_committed(self):
        manifest, _tip = self.sealed_session("export-empty")
        work = Path(manifest["workspace"]["workspace"])
        subprocess.run(
            [
                session.workspace.GIT,
                "-C",
                str(work),
                "-c",
                "core.hooksPath=/dev/null",
                "reset",
                "--hard",
                "-q",
                manifest["workspace"]["snapshot_commit"],
            ],
            env=session.workspace._environment(),
            check=True,
        )
        with self.assertRaisesRegex(session.SessionError, "commit changes"):
            session.export_session(manifest)

    def test_export_refuses_a_replaced_session_root(self):
        manifest, _tip = self.sealed_session("export-replaced")
        session_root = Path(manifest["workspace"]["session_root"])
        session_root.rename(self.root / "stolen-session")
        session_root.mkdir(mode=0o700)
        with self.assertRaisesRegex(session.SessionError, "replaced"):
            session.export_session(manifest)

    def land(self, manifest):
        """Landing's message with its prefixes and wrapping undone."""
        output = io.StringIO()
        with redirect_stderr(output):
            session.land(manifest)
        return " ".join(
            line.removeprefix("alamode:").strip()
            for line in output.getvalue().splitlines()
        )

    def git_in(self, where, *args):
        return subprocess.run(
            [
                session.workspace.GIT,
                "-C",
                str(where),
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "commit.gpgsign=false",
                *args,
            ],
            env=session.workspace._environment(),
            capture_output=True,
            text=True,
        )

    def test_land_fast_forwards_a_clean_launch(self):
        manifest, tip = self.sealed_session("land-clean")
        source = Path(manifest["workspace"]["source"])
        before = self.git_in(source, "rev-parse", "HEAD").stdout.strip()
        self.git_in(source, "branch", "alamode")
        message = self.land(manifest)
        self.assertEqual(self.git_in(source, "rev-parse", "HEAD").stdout.strip(), tip)
        self.assertEqual((source / "file").read_text(), "agent change\n")
        self.assertIn("Fast-forwarded main by 1 commit,", message)
        self.assertIn(f"git log -p {before[:12]}..{tip[:12]}", message)
        self.assertIn(f"git adopt {before[:12]}", message)
        self.assertIn(f"git reset --keep {before[:12]}", message)
        self.assertNotIn("unwip", message)
        # Only work left for the human keeps a branch.
        self.assertTrue(
            self.git_in(
                source, "rev-parse", "-q", "--verify", "alamode-fixture"
            ).returncode
        )
        # A resumed session that quits with nothing new says so.
        self.assertIn("Nothing new to land", self.land(manifest))

    def test_land_says_when_there_is_nothing_to_land(self):
        manifest, _tip = self.sealed_session("land-none")
        work = Path(manifest["workspace"]["workspace"])
        self.git_in(
            work, "reset", "--hard", "-q", manifest["workspace"]["snapshot_commit"]
        )
        self.assertIn("No commits this session", self.land(manifest))

    def test_land_names_the_wip_commit(self):
        manifest, _tip = self.sealed_session("land-wip")
        work = Path(manifest["workspace"]["workspace"])
        (work / "left").write_text("unsaved\n")
        self.git_in(work, "add", "left")
        self.git_in(work, "commit", "-qm", session.WIP_SUBJECT)
        message = self.land(manifest)
        self.assertIn("Fast-forwarded main by 2 commits,", message)
        self.assertIn(f'The last commit, "{session.WIP_SUBJECT}"', message)
        self.assertIn("git reset --soft HEAD~1", message)

    def test_land_points_a_session_outside_git_at_export(self):
        metadata = session.workspace.create_empty(
            self.root / "land-empty-session",
            "fixture",
            record_root=self.records / "land-empty-records",
        )
        work = Path(metadata["workspace"])
        (work / "notes").write_text("notes\n")
        self.git_in(work, "add", "notes")
        self.git_in(work, "commit", "-qm", "Notes")
        message = self.land({**self.manifest, "workspace": metadata})
        self.assertIn("started outside a repository", message)
        self.assertIn("alamode sessions export fixture", message)

    def test_land_leaves_a_branch_when_the_checkout_moved(self):
        manifest, tip = self.sealed_session("land-moved")
        source = Path(manifest["workspace"]["source"])
        (source / "human").write_text("human\n")
        self.git_in(source, "add", "human")
        self.git_in(source, "commit", "-qm", "Human")
        moved = self.git_in(source, "rev-parse", "HEAD").stdout.strip()
        message = self.land(manifest)
        self.assertEqual(self.git_in(source, "rev-parse", "HEAD").stdout.strip(), moved)
        self.assertEqual(
            self.git_in(source, "rev-parse", "alamode-fixture").stdout.strip(), tip
        )
        base = manifest["workspace"]["snapshot_commit"]
        self.assertIn("1 commit is waiting on alamode-fixture.", message)
        self.assertIn("main was NOT moved: git refused to fast-forward it", message)
        self.assertIn(
            f"git cherry-pick {base[:12]}..alamode-fixture && git adopt {moved[:12]}",
            message,
        )
        self.assertIn("git branch -D alamode-fixture", message)

    def test_land_keeps_a_dirty_launch_off_the_checkout(self):
        manifest, tip = self.sealed_session("land-dirty", dirty=True)
        source = Path(manifest["workspace"]["source"])
        head = self.git_in(source, "rev-parse", "HEAD").stdout.strip()
        snapshot = manifest["workspace"]["snapshot_commit"]
        self.assertNotEqual(snapshot, head)
        message = self.land(manifest)
        self.assertEqual(self.git_in(source, "rev-parse", "HEAD").stdout.strip(), head)
        self.assertEqual((source / "wip").read_text(), "human wip\n")
        self.assertEqual(
            self.git_in(source, "rev-parse", "alamode-fixture").stdout.strip(), tip
        )
        self.assertIn("main was NOT moved: the session started from your", message)
        # The range leaves out the snapshot commit holding the human's edits,
        # so a fast-forward, which would carry it, is never offered.
        self.assertIn(
            f"git cherry-pick {snapshot[:12]}..alamode-fixture && git adopt {head[:12]}",
            message,
        )
        self.assertNotIn("--ff-only", message)

    def test_land_holds_context_files_and_skips_children(self):
        manifest, _tip = self.sealed_session("land-context")
        source = Path(manifest["workspace"]["source"])
        work = Path(manifest["workspace"]["workspace"])
        (work / "AGENTS.md").write_text("model-authored steering\n")
        self.git_in(work, "add", "AGENTS.md")
        self.git_in(work, "commit", "-qm", "Steer")
        head = self.git_in(source, "rev-parse", "HEAD").stdout.strip()
        self.assertEqual(self.land({**manifest, "coordinator": {"role": "child"}}), "")
        self.assertTrue(
            self.git_in(
                source, "rev-parse", "-q", "--verify", "alamode-fixture"
            ).returncode
        )
        message = self.land(manifest)
        self.assertEqual(self.git_in(source, "rev-parse", "HEAD").stdout.strip(), head)
        self.assertIn(
            "2 commits are waiting on alamode-fixture. main was NOT moved.", message
        )
        self.assertIn("read as instructions: AGENTS.md pi and Claude", message)
        self.assertIn(
            f"git merge --ff-only alamode-fixture && git adopt {head[:12]}", message
        )

    def test_landing_notice_says_at_launch_where_commits_go(self):
        manifest, _tip = self.sealed_session("notice-clean")
        self.assertEqual(
            session.landing_notice(manifest),
            (
                "info",
                "Quitting fast-forwards main with this session's commits."
                " Commits that change files your agents read as instructions"
                " wait on alamode-fixture instead.",
                "fast-forwards main on quit",
            ),
        )
        environment = session.child_environment(
            self.config, manifest, self.root, self.work / "runtime"
        )
        self.assertEqual(environment["ALAMODE_LANDING_LEVEL"], "info")
        self.assertEqual(
            environment["ALAMODE_LANDING_SHORT"], "fast-forwards main on quit"
        )
        self.assertEqual(environment["ALAMODE_SOURCE_BRANCH"], "main")
        self.assertEqual(
            environment["ALAMODE_SNAPSHOT_COMMIT"],
            manifest["workspace"]["snapshot_commit"],
        )
        self.assertTrue(
            manifest["workspace"]["source"].endswith(
                environment["ALAMODE_SOURCE"].removeprefix("~")
            )
        )
        self.assertNotIn("ALAMODE_LOCAL", environment)
        self.assertNotIn("ALAMODE_ALLOWED_HOSTS", environment)
        allowed = session.child_environment(
            self.config,
            {
                **manifest,
                "policy": {
                    **manifest["policy"],
                    "allow": ["a.example.invalid", "b.example.invalid"],
                },
            },
            self.root,
            self.work / "runtime",
        )
        self.assertEqual(
            allowed["ALAMODE_ALLOWED_HOSTS"], "a.example.invalid,b.example.invalid"
        )
        local = session.child_environment(
            self.config,
            {
                **manifest,
                "policy": {**manifest["policy"], "local": True, "allowed_models": []},
            },
            self.root,
            self.work / "runtime",
        )
        self.assertEqual(local["ALAMODE_LOCAL"], "1")
        level, text, short = session.landing_notice(
            {**manifest, "workspace": {**manifest["workspace"], "source_ref": None}}
        )
        self.assertEqual(level, "warning")
        self.assertIn("did not start on a branch", text)
        self.assertEqual(short, "waits on alamode-fixture")
        self.assertIsNone(
            session.landing_notice({**manifest, "coordinator": {"role": "child"}})
        )

        dirty, _tip = self.sealed_session("notice-dirty", dirty=True)
        level, text, short = session.landing_notice(dirty)
        self.assertEqual(level, "warning")
        self.assertIn("quitting will NOT move main", text)
        self.assertEqual(short, "waits on alamode-fixture, main will NOT move")
        # A session with commits already has work to land, so starting over
        # is offered only before the first one.
        self.assertNotIn("launch again", text)
        work = Path(dirty["workspace"]["workspace"])
        self.git_in(
            work, "reset", "--hard", "-q", dirty["workspace"]["snapshot_commit"]
        )
        self.assertIn("quit now", session.landing_notice(dirty)[1])

        metadata = session.workspace.create_empty(
            self.root / "notice-empty-session",
            "fixture",
            record_root=self.records / "notice-empty-records",
        )
        level, text, short = session.landing_notice(
            {**self.manifest, "workspace": metadata}
        )
        self.assertEqual(level, "info")
        self.assertIn("outside a repository", text)
        self.assertEqual(short, "stays in the session")

    def test_admission_refuses_planted_guard_config_casings(self):
        source = self.root / "guard-source"
        source.mkdir()
        git_env = session.workspace._environment()

        def git(where, *args):
            return subprocess.run(
                [session.workspace.GIT, "-C", str(where), *args],
                env=git_env,
                check=True,
                capture_output=True,
                text=True,
            )

        git(source, "init", "-q", "-b", "main")
        (source / "initial").write_text("initial")
        git(source, "add", ".")
        git(
            source,
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "Fixture",
        )
        # APFS is case-insensitive, so a variant-cased plant that slips a
        # literal path deny still aliases the name the guards load. Export
        # admission must refuse every casing.
        for index, (folder, name) in enumerate(
            (
                (".PI", "Secret-Guard.JSON"),
                (".pi", "secret-guard.json"),
                (".Pi", "Verify.JSON"),
                (".pi", "verify.json"),
            )
        ):
            with self.subTest(casing=(folder, name)):
                metadata = session.workspace.create(
                    source,
                    self.root / f"guard-session-{index}",
                    "fixture",
                    record_root=self.records / f"guard-fixture-{index}",
                )
                work = Path(metadata["workspace"])
                (work / folder).mkdir()
                (work / folder / name).write_text('{"enabled": false}')
                git(work, "add", ".")
                git(
                    work,
                    "-c",
                    "core.hooksPath=/dev/null",
                    "-c",
                    "commit.gpgsign=false",
                    "commit",
                    "-qm",
                    "Plant",
                )
                tip = git(work, "rev-parse", "HEAD").stdout.strip()
                bundle = Path(metadata["session_root"]) / "proposal.bundle"
                git(
                    work,
                    "bundle",
                    "create",
                    str(bundle),
                    "HEAD",
                    "^" + metadata["snapshot_commit"],
                )
                with self.assertRaisesRegex(
                    session.workspace.WorkspaceError, "protected content"
                ):
                    session.workspace.admit_bundle(
                        metadata,
                        bundle,
                        self.root / f"guard-quarantine-{index}",
                        tip,
                        "guardcase",
                    )

    def test_environment_and_web_filesystem_parity(self):
        runtime = self.work / "runtime"
        with patch.dict(
            os.environ,
            {
                "PROVIDER_SECRET": KEY,
                "BASH_ENV": "evil",
                "NODE_OPTIONS": "evil",
                "PYTHONPATH": "evil",
            },
        ):
            environment = session.child_environment(
                self.config, self.manifest, self.root, runtime
            )
        for name in ("PROVIDER_SECRET", "BASH_ENV", "NODE_OPTIONS", "PYTHONPATH"):
            self.assertNotIn(name, environment)
        self.assertNotIn(KEY, json.dumps(environment))
        strict = session.sandbox_policy(self.config, self.manifest, runtime, 12345)
        self.manifest["policy"]["web"] = True
        web = session.sandbox_policy(self.config, self.manifest, runtime, 12345)
        self.assertEqual(strict["filesystem"], web["filesystem"])
        self.assertFalse(web["network"]["allowLocalBinding"])
        self.assertIn("127.0.0.1:12345", web["network"]["allowedDomains"])
        self.assertIn("127.0.0.0/8", web["network"]["deniedResolvedAddresses"])
        self.assertEqual(environment["GIT_CONFIG_VALUE_0"], "/dev/null")

    def test_credential_reference_semantics(self):
        env = {"TOKEN": "fixture-value"}
        self.assertEqual(session.resolver("$TOKEN", env, self.config), "fixture-value")
        self.assertEqual(
            session.resolver("Bearer ${TOKEN}", env, self.config),
            "Bearer fixture-value",
        )
        self.assertEqual(session.resolver("$$TOKEN", env, self.config), "$TOKEN")
        self.assertEqual(session.resolver("$!literal", env, self.config), "!literal")
        self.assertEqual(session.resolver("TOKEN", env, self.config), "TOKEN")
        with self.assertRaises(session.SessionError):
            session.resolver("$MISSING", env, self.config)

    def test_credentials_preserve_model_headers_and_enforce_gates(self):
        catalog = {
            "providers": {
                "fixture": {
                    "api": "openai-completions",
                    "baseUrl": "https://provider.example.invalid/v1",
                    "apiKey": "$PRIMARY_KEY",
                    "headers": {"Authorization": "Bearer ${PRIMARY_KEY}"},
                    "modelOverrides": {
                        "probe": {
                            "headers": {
                                "X-Fixture": "override",
                                "X-Override": "$PRIMARY_KEY",
                            }
                        }
                    },
                    "models": [{"id": "probe", "headers": {"X-Fixture": "model"}}],
                }
            }
        }
        Path(self.config["catalogFile"]).write_text(json.dumps(catalog))
        self.config["resolvers"] = {"PRIMARY_KEY": "printf resolved-fixture"}
        self.config["resolverGates"] = {"PRIMARY_KEY": "registry"}
        with patch.dict(os.environ, {"PRIMARY_KEY": "inherited-must-not-bypass-gate"}):
            with self.assertRaises(session.SessionError):
                session.credentials(self.config, self.manifest, self.root)
            self.manifest["policy"]["grants"] = ["registry"]
            _, auth = session.credentials(self.config, self.manifest, self.root)
        self.assertEqual(auth["fixture"]["apiKey"], "resolved-fixture")
        self.assertEqual(
            auth["fixture"]["headers"]["Authorization"], "Bearer resolved-fixture"
        )
        self.assertEqual(
            auth["fixture"]["modelHeaders"]["probe"],
            {"X-Fixture": "model", "X-Override": "resolved-fixture"},
        )
        self.config["bundles"]["kagi"] = {"domains": []}
        self.config["resolvers"]["KAGI_API_KEY"] = "printf synthetic-kagi-key"
        self.config["resolverGates"]["KAGI_API_KEY"] = "kagi"
        _, _, tools = session.credentials(
            self.config, self.manifest, self.root, include_tools=True
        )
        self.assertEqual(tools, {})
        self.manifest["policy"]["grants"].append("kagi")
        _, _, tools = session.credentials(
            self.config, self.manifest, self.root, include_tools=True
        )
        self.assertEqual(tools, {"kagi": "synthetic-kagi-key"})

    def test_prepare_refuses_parent_symlinks_and_replaces_file_symlinks(self):
        class Relay:
            catalog = {"providers": {}}

        runtime = session.prepare(self.config, self.manifest, Relay())
        sentinel = self.root / "outside"
        sentinel.write_text("unchanged")
        models = runtime / "agent/models.json"
        models.unlink()
        models.symlink_to(sentinel)
        session.prepare(self.config, self.manifest, Relay())
        self.assertEqual(sentinel.read_text(), "unchanged")
        self.assertFalse(models.is_symlink())
        shutil.rmtree(runtime / "agent")
        (runtime / "agent").symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(session.SessionError, "agent state"):
            session.prepare(self.config, self.manifest, Relay())
        self.assertFalse((self.root / "settings.json").exists())

    def test_prepare_refuses_replaced_trusted_directories(self):
        class Relay:
            catalog = {"providers": {}}

        worktree = Path(self.manifest["workspace"]["workspace"])
        dot_pi = worktree / ".pi"
        dot_pi.mkdir()
        (self.work / "runtime" / "agent").mkdir(parents=True)
        storage = Path(self.manifest["workspace"]["common_dir"])

        def swap(path):
            moved = path.with_name(path.name + "-swapped")
            path.rename(moved)
            path.symlink_to(moved, target_is_directory=True)

        def restore(path):
            path.unlink()
            path.with_name(path.name + "-swapped").rename(path)

        # Seatbelt write denies match resolved paths, so a symlinked parent
        # is the spelling a plant hides under; every directory pi loads
        # trusted material from must refuse the swap by name.
        for label, path in (
            ("workspace", worktree),
            ("project configuration", dot_pi),
            ("session runtime", self.work / "runtime"),
            ("agent state", self.work / "runtime" / "agent"),
            ("private Git storage", storage),
        ):
            with self.subTest(replaced=label):
                swap(path)
                with self.assertRaisesRegex(session.SessionError, label):
                    session.prepare(self.config, self.manifest, Relay())
                restore(path)

        # Real directories, a repository's own .pi included, must pass.
        session.prepare(self.config, self.manifest, Relay())

    def test_sandbox_denies_plantable_guard_and_agent_bin_paths(self):
        rules = session.sandbox_policy(
            self.config, self.manifest, self.work / "runtime", 0
        )
        workspace = Path(self.manifest["workspace"]["workspace"])
        expected = [
            session.cased_deny(self.work, workspace / ".pi" / "secret-guard.json"),
            session.cased_deny(self.work, workspace / ".pi" / "verify.json"),
            session.cased_deny(
                self.work, self.work / "runtime" / "agent" / "secret-guard.json"
            ),
            session.cased_deny(
                self.work, self.work / "runtime" / "agent" / "verify.json"
            ),
            session.cased_deny(self.work, self.work / "runtime" / "agent" / "bin"),
            session.cased_deny(self.work, self.work / "runtime" / "agent" / "npm"),
        ]
        for entry in expected:
            self.assertIn(entry, rules["filesystem"]["denyWrite"])
        if sys.platform != "darwin":
            return
        # APFS resolves names case-insensitively while Seatbelt regexes are
        # case-sensitive, so every variant spelling of every plantable path
        # must still match some deny entry; the character classes guarantee it.
        variants = []
        for name in ("secret-guard.json", "verify.json"):
            for dot_pi in (".pi", ".PI", ".Pi"):
                for worktree in ("worktree", "Worktree"):
                    variants.append(self.work / worktree / dot_pi / name)
        for name in ("secret-guard.json", "verify.json"):
            for runtime in ("runtime", "Runtime"):
                for agent in ("agent", "Agent"):
                    variants.append(self.work / runtime / agent / name)
        for agent_bin in ("bin", "BIN", "Bin"):
            for runtime in ("runtime", "Runtime"):
                for agent in ("agent", "Agent"):
                    variants.append(self.work / runtime / agent / agent_bin)
        for path in variants:
            with self.subTest(path=path):
                self.assertTrue(
                    any(
                        self._glob_matches(entry, str(path))
                        for entry in rules["filesystem"]["denyWrite"]
                    ),
                    f"{path} slips every denyWrite entry",
                )

    def test_sandbox_denies_session_task_logs(self):
        rules = session.sandbox_policy(
            self.config, self.manifest, self.work / "runtime", 0
        )
        self.assertIn(
            session.cased_deny(
                self.work, self.work / "runtime" / "agent" / "task-logs"
            ),
            rules["filesystem"]["denyRead"],
        )
        # The job logs stall-guard points the model at stay readable.
        self.assertNotIn("job-logs", str(rules["filesystem"]["denyRead"]).lower())
        if sys.platform != "darwin":
            return
        variants = []
        for task in ("task-logs", "TASK-LOGS", "Task-Logs"):
            for runtime in ("runtime", "Runtime"):
                for agent in ("agent", "Agent"):
                    variants.append(self.work / runtime / agent / task)
        for path in variants:
            with self.subTest(path=path):
                self.assertTrue(
                    any(
                        self._glob_matches(entry, str(path))
                        for entry in rules["filesystem"]["denyRead"]
                    ),
                    f"{path} slips every denyRead entry",
                )

    def test_sandbox_reads_grants_as_paths(self):
        grant = str(self.root / "alam*")
        self.manifest["policy"]["read"] = []
        self.manifest["policy"]["write"] = [grant]
        rules = session.sandbox_policy(
            self.config, self.manifest, self.work / "runtime", 0
        )
        entry = {"path": grant, "literal": True}
        self.assertIn(entry, rules["filesystem"]["allowWrite"])
        self.assertIn(entry, rules["filesystem"]["allowRead"])
        self.assertNotIn(grant, rules["filesystem"]["allowWrite"])

    def test_pin_store_roots_registers_deployment_packages(self):
        gcroots = self.root / "gcroots"
        config = {
            "pi": "/nix/store/" + "h0" * 16 + "-pi-1.0.0/bin/pi",
            "node": "/nix/store/" + "b1" * 16 + "-nodejs-24.21.0/bin/node",
            "sandboxRunner": "/nix/store/"
            + "c2" * 16
            + "-sandbox-runtime-0.0.78/libexec/x/sandbox.mjs",
            # The colon-joined PATH list is not a store path and pins nothing.
            "path": "/nix/store/" + "d3" * 16 + "-fd-10.4.2/bin:/usr/bin",
            "settingsFile": str(self.root / "settings.json"),
            "builder": "",
        }
        session.pin_store_roots(config, directories=[gcroots])
        self.assertEqual(
            sorted(path.name for path in gcroots.iterdir()),
            [
                "alamode-" + "b1" * 16 + "-nodejs-24.21.0",
                "alamode-" + "c2" * 16 + "-sandbox-runtime-0.0.78",
                "alamode-" + "h0" * 16 + "-pi-1.0.0",
            ],
        )
        self.assertEqual(
            os.readlink(gcroots / ("alamode-" + "h0" * 16 + "-pi-1.0.0")),
            "/nix/store/" + "h0" * 16 + "-pi-1.0.0",
        )
        # Re-pinning an unchanged deployment replaces nothing, and a newer
        # deployment adds its own name while leaving the old one for
        # sessions still running on it.
        session.pin_store_roots(config, directories=[gcroots])
        config["pi"] = "/nix/store/" + "e4" * 16 + "-pi-1.1.0/bin/pi"
        session.pin_store_roots(config, directories=[gcroots])
        self.assertTrue((gcroots / ("alamode-" + "e4" * 16 + "-pi-1.1.0")).is_symlink())
        self.assertTrue((gcroots / ("alamode-" + "h0" * 16 + "-pi-1.0.0")).is_symlink())
        self.assertFalse(
            any(path.name.startswith("alamode-tmp-") for path in gcroots.iterdir())
        )
        # A gcroots directory that cannot be created changes nothing.
        barrier = self.root / "barrier"
        barrier.write_text("a file blocks the directory path")
        session.pin_store_roots(config, directories=[barrier / "gcroots"])
        self.assertFalse((barrier / "gcroots").exists())

        # Where no scanned gcroots directory is writable, the same roots are
        # registered as indirect roots under the private control directory,
        # and the daemon owns the gcroots/auto link. A stub stands in for
        # nix-store and creates the root like the real one does.
        control = self.root / "pin-control"
        control.mkdir(mode=0o700)
        calls = []

        def stub(command, **_keywords):
            calls.append(command)
            link = Path(command[command.index("--add-root") + 1])
            link.symlink_to(command[-1])
            return subprocess.CompletedProcess(command, 0)

        with patch.object(session.subprocess, "run", side_effect=stub):
            session.pin_store_roots(
                config, directories=[], control=control, store_tool="nix-store"
            )
        self.assertEqual(len(calls), 3)
        self.assertEqual(
            sorted(path.name for path in (control / "gcroots").iterdir()),
            [
                "alamode-" + "b1" * 16 + "-nodejs-24.21.0",
                "alamode-" + "c2" * 16 + "-sandbox-runtime-0.0.78",
                "alamode-" + "e4" * 16 + "-pi-1.1.0",
            ],
        )
        # Roots already pinned as indirect roots register nothing further.
        with patch.object(session.subprocess, "run", side_effect=stub):
            session.pin_store_roots(
                config, directories=[], control=control, store_tool="nix-store"
            )
        self.assertEqual(len(calls), 3)
        # Roots a writable gcroots directory took need no indirect root at all.
        writable = self.root / "writable-gcroots"
        with patch.object(session.subprocess, "run", side_effect=stub):
            session.pin_store_roots(
                config, directories=[writable], control=control, store_tool="nix-store"
            )
        self.assertEqual(len(calls), 3)
        self.assertTrue(
            (writable / ("alamode-" + "e4" * 16 + "-pi-1.1.0")).is_symlink()
        )

    @staticmethod
    def _glob_matches(pattern, path):
        # Translate a cased deny entry (a shell-style glob whose only glob
        # syntax is [aA] character classes) into a regex and match `path`.
        import re

        result = ""
        index = 0
        while index < len(pattern):
            character = pattern[index]
            if character == "[":
                end = pattern.index("]", index)
                result += "[" + re.escape(pattern[index + 1 : end]) + "]"
                index = end + 1
            else:
                result += re.escape(character)
                index += 1
        return re.fullmatch(result, path) is not None

    def test_host_editor_resolves_the_callers_editor(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        editor = bin_dir / "editor-probe"
        editor.write_text("#!/bin/sh\n")
        editor.chmod(0o755)
        path = {"PATH": str(bin_dir)}
        cases = (
            ({"VISUAL": "editor-probe -f", "EDITOR": "absent"}, f"{editor} -f"),
            ({"EDITOR": "editor-probe"}, str(editor)),
            ({"VISUAL": "absent"}, None),
            ({}, None),
        )
        for variables, expected in cases:
            with self.subTest(variables=variables):
                with patch.dict(os.environ, {**path, **variables}, clear=True):
                    self.assertEqual(session.host_editor(), expected)

    def test_prepare_reclaims_planted_agent_state(self):
        class Relay:
            catalog = {"providers": {}}

        source = self.root / "deployed"
        (source / "agents").mkdir(parents=True)
        (source / "agents" / "scout.md").write_text("deployed agent")
        (source / "skills").mkdir()
        (source / "skills" / "probe.md").write_text("deployed skill")
        self.config["runtimeSource"] = str(source)
        runtime = session.prepare(self.config, self.manifest, Relay())
        agent = runtime / "agent"
        # Files pi and its guards load with no trust decision.
        for name in (
            "mcp.json",
            "mcp-auth.json",
            "trust.json",
            "models-store.json",
            "secret-guard.json",
            "verify.json",
        ):
            (agent / name).write_text("{}")
        # Prompt and instruction files pi loads with no trust decision.
        (agent / "SYSTEM.md").write_text("planted system prompt")
        (agent / "APPEND_SYSTEM.md").write_text("planted append")
        (agent / "AGENTS.md").write_text("planted instructions")
        (agent / "AGENTS.override.md").write_text("planted override")
        (agent / "prompts").mkdir()
        (agent / "prompts" / "evil.md").write_text("planted slash command")
        (agent / "keybindings.json").write_text("{}")
        # Tool shadowing trees, with nested content.
        planted_bin = agent / "bin"
        planted_bin.mkdir()
        (planted_bin / "fd").write_text("#!/bin/sh")
        (planted_bin / "nested").mkdir()
        (planted_bin / "nested" / "rg").write_text("#!/bin/sh")
        planted_npm = agent / "npm"
        (planted_npm / "package").mkdir(parents=True)
        (planted_npm / "package" / "index.js").write_text("module.exports = 1")
        # Extras planted beside files the recopy overwrites.
        (agent / "extensions").mkdir()
        (agent / "extensions" / "planted.js").write_text("throw 1")
        (agent / "agents" / "planted.md").write_text("planted agent")
        (agent / "skills" / "planted.md").write_text("planted skill")
        # Symlinks must be removed without following them.
        sentinel = self.root / "sentinel"
        sentinel.mkdir()
        (sentinel / "keep").write_text("sentinel")
        (agent / "trust.json").unlink()
        (agent / "trust.json").symlink_to(self.root / "elsewhere")
        (agent / "themes").symlink_to(sentinel, target_is_directory=True)
        # pi's own writable state must survive the reclaim.
        (agent / "secret-guard-violations.log").write_text("{}\n")
        for name in ("task-logs", "job-logs", "sessions"):
            (agent / name).mkdir()
            (agent / name / "probe.log").write_text(name)

        session.prepare(self.config, self.manifest, Relay())

        # Reclaimed names the store recopy does not restore are gone;
        # agents and skills come back holding exactly the deployed files.
        for name in (
            "mcp.json",
            "mcp-auth.json",
            "trust.json",
            "models-store.json",
            "secret-guard.json",
            "verify.json",
            "extensions",
            "themes",
            "bin",
            "npm",
            "SYSTEM.md",
            "APPEND_SYSTEM.md",
            "AGENTS.md",
            "AGENTS.override.md",
            "AGENTS.MD",
            "CLAUDE.md",
            "CLAUDE.MD",
            "prompts",
            "keybindings.json",
        ):
            self.assertFalse((agent / name).exists(), name)
        self.assertTrue((agent / "agents").is_dir())
        self.assertTrue((agent / "skills").is_dir())
        self.assertEqual((sentinel / "keep").read_text(), "sentinel")
        for path in (
            agent / "secret-guard-violations.log",
            agent / "task-logs" / "probe.log",
            agent / "job-logs" / "probe.log",
            agent / "sessions" / "probe.log",
        ):
            self.assertTrue(path.exists(), str(path))
        self.assertEqual((agent / "agents" / "scout.md").read_text(), "deployed agent")
        self.assertFalse((agent / "agents" / "planted.md").exists())
        self.assertEqual((agent / "skills" / "probe.md").read_text(), "deployed skill")
        self.assertFalse((agent / "skills" / "planted.md").exists())

    def test_safe_clear_bounds_planted_depth(self):
        deep = self.work / "runtime" / "agent" / "bin"
        current = deep
        for _ in range(40):
            current = current / "nested"
        current.mkdir(parents=True)
        with self.assertRaisesRegex(session.SessionError, "deeper than 32"):
            session.safe_clear(self.work, "runtime/agent/bin")


class Provider(BaseHTTPRequestHandler):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.calls.append((dict(self.headers), request))
        tool_results = [
            message for message in request["messages"] if message["role"] == "tool"
        ]
        if tool_results:
            delta = {"role": "assistant", "content": "session fixture complete"}
            reason = "stop"
        else:
            delta = {
                "role": "assistant",
                "tool_calls": [
                    {
                        "index": 0,
                        "id": "fixture_call",
                        "type": "function",
                        "function": {
                            "name": "bash",
                            "arguments": json.dumps({"command": self.server.command}),
                        },
                    }
                ],
            }
            reason = "tool_calls"
        if hasattr(self.server, "reply"):
            delta, reason = self.server.reply(request)
        head = {
            "id": "fixture",
            "object": "chat.completion.chunk",
            "created": 0,
            "model": "probe",
            "choices": [{"index": 0, "delta": delta, "finish_reason": None}],
        }
        tail = {**head, "choices": [{"index": 0, "delta": {}, "finish_reason": reason}]}
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(
            b"data: "
            + json.dumps(head).encode()
            + b"\n\ndata: "
            + json.dumps(tail).encode()
            + b"\n\ndata: [DONE]\n\n"
        )

    def log_message(self, *_):
        pass


@unittest.skipUnless(
    os.environ.get("ALAMODE_NATIVE_TESTS") == "1" and sys.platform == "darwin",
    "Native Seatbelt integration is opt-in outside the Nix build sandbox",
)
class NativeSessionTests(unittest.TestCase):
    @unittest.skipUnless(
        os.environ.get("ALAMODE_COORDINATOR_BIN")
        and os.environ.get("ALAMODE_COORDINATOR_EXTENSION"),
        "Set ALAMODE_COORDINATOR_BIN and ALAMODE_COORDINATOR_EXTENSION for native coordinator integration",
    )
    def test_real_coordinator_socket_child_and_reconnect(self):
        import shlex
        import uuid

        with tempfile.TemporaryDirectory(
            prefix="alamode-coordinator-native-", dir="/private/tmp"
        ) as temporary:
            root = Path(temporary)
            home, source = root / "home", root / "source"
            home.mkdir()
            source.mkdir()
            config = configuration(root)
            config["coordinatorDaemon"] = os.environ["ALAMODE_COORDINATOR_BIN"]
            config["resolvers"] = {"PI_PROVIDER_SECRET": "printf " + shlex.quote(KEY)}
            config["runtimeSource"] = str(root / "trusted-runtime")
            extensions = Path(config["runtimeSource"]) / "extensions"
            extensions.mkdir(parents=True)
            shutil.copyfile(
                os.environ["ALAMODE_COORDINATOR_EXTENSION"],
                extensions / "coordinator.ts",
            )
            config["systemReadPaths"].append(config["runtimeSource"])
            config["piArgs"] = ["--model", "fixture/probe"]
            Path(config["sandboxRunner"]).write_text(
                Path(
                    os.environ.get(
                        "ALAMODE_SANDBOX_RUNNER_SOURCE", MODULE.with_name("sandbox.mjs")
                    )
                )
                .read_text()
                .replace("@sandboxRuntime@", os.environ["ALAMODE_SANDBOX_RUNTIME"])
            )
            environment = {
                "HOME": str(home),
                "PATH": os.environ["PATH"],
                "TMPDIR": str(root),
                "PI_SKIP_VERSION_CHECK": "1",
                "PI_TELEMETRY": "0",
                "TERM": "dumb",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_AUTHOR_NAME": "Fixture",
                "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                "GIT_COMMITTER_NAME": "Fixture",
                "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            }
            for args in (["init", "-q", "-b", "main"],):
                subprocess.run(
                    ["git", "-C", str(source), *args], env=environment, check=True
                )
            (source / "initial").write_text("source fixture")
            subprocess.run(
                ["git", "-C", str(source), "add", "."], env=environment, check=True
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(source),
                    "-c",
                    "core.hooksPath=/dev/null",
                    "-c",
                    "commit.gpgsign=false",
                    "commit",
                    "-qm",
                    "Fixture",
                ],
                env=environment,
                check=True,
            )
            provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
            provider.daemon_threads = True
            provider.calls = []
            provider.command = "printf child-fixture"

            def reply(request):
                names = {tool["function"]["name"] for tool in request.get("tools", [])}
                messages = request["messages"]
                last_user = max(
                    index
                    for index, message in enumerate(messages)
                    if message["role"] == "user"
                )
                results = [
                    message
                    for message in messages[last_user + 1 :]
                    if message["role"] == "tool"
                ]
                if "spawn_agent" in names:
                    steps = (
                        [("agent_status", {})]
                        if "Reconnected fixture" in str(messages[last_user])
                        else [
                            (
                                "spawn_agent",
                                {
                                    "agent": "fixture",
                                    "task": "Child fixture",
                                    "model": "fixture/probe",
                                },
                            ),
                            ("agent_wait", {"agent": "fixture", "minutes": 0.25}),
                        ]
                    )
                else:
                    steps = [
                        (
                            "bash",
                            {
                                "command": 'test -z "${PI_PROVIDER_SECRET:-}" && test "$ALAMODE_COORD_ROLE" = child && printf child-fixture'
                            },
                        ),
                        ("report_result", {"message": "child native report"}),
                    ]
                if len(results) >= len(steps):
                    return {
                        "role": "assistant",
                        "content": "native coordinator complete",
                    }, "stop"
                name, arguments = steps[len(results)]
                return {
                    "role": "assistant",
                    "tool_calls": [
                        {
                            "index": 0,
                            "id": "call_" + str(len(results)),
                            "type": "function",
                            "function": {
                                "name": name,
                                "arguments": json.dumps(arguments),
                            },
                        }
                    ],
                }, "tool_calls"

            provider.reply = reply
            threading.Thread(target=provider.serve_forever, daemon=True).start()
            Path(config["catalogFile"]).write_text(
                json.dumps(
                    {
                        "providers": {
                            "fixture": {
                                "api": "openai-completions",
                                "baseUrl": f"http://127.0.0.1:{provider.server_port}/v1",
                                "apiKey": "$PI_PROVIDER_SECRET",
                                "models": [{"id": "probe", "maxTokens": 1024}],
                            }
                        }
                    }
                )
            )
            config_file = root / "config.json"
            config_file.write_text(json.dumps(config))
            launcher = root / "alamode-launcher"
            launcher.write_text(
                f"#!{sys.executable}\nimport os,sys\nos.execv(sys.executable,[sys.executable,{str(MODULE)!r},{str(config_file)!r},{str(launcher)!r},*sys.argv[1:]])\n"
            )
            launcher.chmod(0o700)
            credential = None
            coord = None

            def request(op, **fields):
                with socket.socket(socket.AF_UNIX) as client:
                    client.settimeout(20)
                    client.connect(credential["socket"])
                    client.sendall(
                        (
                            json.dumps(
                                {
                                    "token": credential["token"],
                                    "op": op,
                                    "id": uuid.uuid4().hex,
                                    **fields,
                                }
                            )
                            + "\n"
                        ).encode()
                    )
                    with client.makefile("rb") as stream:
                        response = json.loads(stream.readline())
                self.assertTrue(response["ok"], response)
                return response["data"]

            try:
                result = subprocess.run(
                    [
                        str(launcher),
                        "coord",
                        "--",
                        "--mode",
                        "json",
                        "Main fixture",
                    ],
                    cwd=source,
                    env=environment,
                    capture_output=True,
                    text=True,
                    timeout=45,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                coords = [
                    path.parent
                    for path in (home / ".local/state/alamode/coordinators").glob(
                        "*/broker.json"
                    )
                ]
                self.assertEqual(len(coords), 1)
                coord = coords[0]
                credential = json.loads(
                    subprocess.check_output(
                        [config["coordinatorDaemon"], "credentials", str(coord)],
                        env=environment,
                    )
                )
                state = request("status", agent="fixture")
                self.assertEqual(state["state"], "idle", state)
                self.assertEqual(state["outcome"]["state"], "success", state)
                self.assertEqual(state["report"]["text"], "child native report")
                self.assertNotIn(KEY, result.stdout + result.stderr)
                result = subprocess.run(
                    [
                        str(launcher),
                        "coord",
                        "attach",
                        coord.name,
                        "--",
                        "--mode",
                        "json",
                        "Reconnected fixture",
                    ],
                    cwd=source,
                    env=environment,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                state = request("status")
                self.assertEqual(
                    [agent["agent"] for agent in state["agents"]], ["fixture"]
                )
                request("teardown", agent="fixture")
                self.assertEqual(request("status", agent="fixture")["state"], "closed")
            finally:
                if coord is None:
                    candidates = [
                        path.parent
                        for path in (home / ".local/state/alamode/coordinators").glob(
                            "*/broker.json"
                        )
                    ]
                    coord = candidates[0] if candidates else None
                if coord:
                    if credential:
                        try:
                            for agent in request("status")["agents"]:
                                request("teardown", agent=agent["agent"])
                        except (OSError, AssertionError):
                            pass
                    for pidfile in [
                        *coord.glob("agents/*/supervisor.pid"),
                        coord / "broker.pid",
                    ]:
                        if pidfile.exists():
                            try:
                                os.kill(int(pidfile.read_text()), signal.SIGTERM)
                            except ProcessLookupError:
                                pass
                    for config_path in [
                        *coord.glob("agents/*/supervisor.json"),
                        coord / "broker.json",
                    ]:
                        if config_path.exists():
                            Path(json.loads(config_path.read_text())["socket"]).unlink(
                                missing_ok=True
                            )
                provider.shutdown()
                provider.server_close()

    def test_real_pi_denies_planted_guard_configs_and_agent_bin(self):
        """Live Seatbelt probe for the plantable-path denies.

        The wrapper ships fd and rg on PATH, so pi's find tool never needs its
        session-denied agent bin dir; the guard configurations must be
        unwritable in every casing, because APFS resolves names
        case-insensitively and a variant-cased plant would otherwise slip a
        literal path deny on the next session start.
        """
        import shlex

        with tempfile.TemporaryDirectory(
            prefix="alamode-session-native-", dir="/private/tmp"
        ) as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            source = root / "source"
            source.mkdir()
            config = configuration(root)
            environment = {
                "HOME": str(home),
                "PATH": config["path"],
                "PI_PROVIDER_SECRET": KEY,
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_AUTHOR_NAME": "Fixture",
                "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                "GIT_COMMITTER_NAME": "Fixture",
                "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            }
            subprocess.run(
                ["git", "init", "-q", "-b", "main", str(source)],
                env=environment,
                check=True,
            )
            (source / "original.txt").write_text("fixture\n")
            subprocess.run(
                ["git", "-C", str(source), "add", "."], env=environment, check=True
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(source),
                    "-c",
                    "commit.gpgsign=false",
                    "-c",
                    "core.hooksPath=/dev/null",
                    "commit",
                    "-qm",
                    "Fixture",
                ],
                env=environment,
                check=True,
            )
            sandbox_source = Path(
                os.environ.get(
                    "ALAMODE_SANDBOX_RUNNER_SOURCE", MODULE.with_name("sandbox.mjs")
                )
            ).read_text()
            sandbox_source = sandbox_source.replace(
                "@sandboxRuntime@", os.environ["ALAMODE_SANDBOX_RUNTIME"]
            )
            Path(config["sandboxRunner"]).write_text(sandbox_source)
            provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
            provider.daemon_threads = True
            provider.calls = []
            threading.Thread(target=provider.serve_forever, daemon=True).start()
            try:
                catalog = {
                    "providers": {
                        "fixture": {
                            "api": "openai-completions",
                            "baseUrl": f"http://127.0.0.1:{provider.server_port}/v1",
                            "apiKey": "$PI_PROVIDER_SECRET",
                            "models": [{"id": "probe", "maxTokens": 1024}],
                        }
                    }
                }
                Path(config["catalogFile"]).write_text(json.dumps(catalog))
                config_file = root / "config.json"
                config_file.write_text(json.dumps(config))
                probe = """import json, os, pathlib, shutil
r={}
def writable(p):
    try: pathlib.Path(p).write_text("planted"); return True
    except OSError: return False
agent=os.environ["PI_CODING_AGENT_DIR"]
pathlib.Path(".pi").mkdir(exist_ok=True)
r["agent_guard"]=writable(os.path.join(agent,"secret-guard.json"))
r["agent_guard_variant"]=writable(os.path.join(agent,"SECRET-GUARD.json"))
r["agent_verify"]=writable(os.path.join(agent,"verify.json"))
r["agent_bin"]=writable(os.path.join(agent,"bin","probe"))
r["agent_bin_variant"]=writable(os.path.join(agent,"BIN","probe"))
r["project_guard"]=writable(".pi/secret-guard.json")
r["project_guard_variant"]=writable(".PI/secret-guard.json")
r["project_verify"]=writable(".pi/verify.json")
r["project_verify_variant"]=writable(".PI/Verify.json")
r["dot_pi_other"]=writable(".pi/other.json")
r["agent_other"]=writable(os.path.join(agent,"other.json"))
r["fd_on_path"]=shutil.which("fd") is not None
r["rg_on_path"]=shutil.which("rg") is not None
print(json.dumps(r))
"""
                provider.command = (
                    shlex.quote(sys.executable) + " -c " + shlex.quote(probe)
                )
                command = [
                    sys.executable,
                    str(MODULE),
                    str(config_file),
                    "/fixture/alamode",
                    "--",
                    "--model",
                    "fixture/probe",
                    "--no-session",
                    "--mode",
                    "json",
                    "Run the fixture",
                ]
                result = subprocess.run(
                    command,
                    cwd=source,
                    env=environment,
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertGreaterEqual(
                    len(provider.calls), 2, result.stdout + result.stderr
                )
                tools = [
                    message
                    for message in provider.calls[-1][1]["messages"]
                    if message["role"] == "tool"
                ]
                report = json.loads(tools[-1]["content"])
                self.assertEqual(
                    report,
                    {
                        "agent_guard": False,
                        "agent_guard_variant": False,
                        "agent_verify": False,
                        "agent_bin": False,
                        "agent_bin_variant": False,
                        "project_guard": False,
                        "project_guard_variant": False,
                        "project_verify": False,
                        "project_verify_variant": False,
                        "dot_pi_other": True,
                        "agent_other": True,
                        "fd_on_path": True,
                        "rg_on_path": True,
                    },
                    report,
                )
            finally:
                provider.shutdown()
                provider.server_close()

    def test_real_pi_strict_web_isolation_and_commits(self):
        import shlex
        from multiprocessing import shared_memory

        with (
            tempfile.TemporaryDirectory(
                prefix="alamode-session-native-", dir="/private/tmp"
            ) as temporary,
            tempfile.NamedTemporaryFile(prefix="alamode-native-canary-") as temp_canary,
        ):
            temp_canary.write(b"synthetic temp canary")
            temp_canary.flush()
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            source = root / "source"
            source.mkdir()
            config = configuration(root)
            environment = {
                "HOME": str(home),
                "PATH": config["path"],
                "PI_PROVIDER_SECRET": KEY,
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_AUTHOR_NAME": "Fixture",
                "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                "GIT_COMMITTER_NAME": "Fixture",
                "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
            }
            subprocess.run(
                ["git", "init", "-q", "-b", "main", str(source)],
                env=environment,
                check=True,
            )
            (source / "original.txt").write_text("fixture\n")
            subprocess.run(
                ["git", "-C", str(source), "add", "."], env=environment, check=True
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(source),
                    "-c",
                    "commit.gpgsign=false",
                    "-c",
                    "core.hooksPath=/dev/null",
                    "commit",
                    "-qm",
                    "Fixture",
                ],
                env=environment,
                check=True,
            )
            c_probe = root / "process-probe.c"
            c_probe.write_text(r"""#include <libproc.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    pid_t pid = atoi(argv[1]);
    struct proc_bsdinfo info;
    mach_port_t service = MACH_PORT_NULL, task = MACH_PORT_NULL;
    int signaling = kill(pid, 0) == 0;
    int process_info = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) > 0;
    int task_port = task_for_pid(mach_task_self(), pid, &task) == KERN_SUCCESS;
    int keychain_service = bootstrap_look_up(bootstrap_port, "com.apple.securityd.xpc", &service) == KERN_SUCCESS;
    int mib[] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t length = 262144;
    char *args = calloc(1, length);
    int args_readable = sysctl(mib, 3, args, &length, NULL, 0) == 0;
    int env_canary = args_readable && memmem(args, length, "synthetic-provider-key-never-in-child", 36) != NULL;
    printf("{\"signal\":%d,\"process_info\":%d,\"task_port\":%d,\"securityd\":%d,\"args_readable\":%d,\"env_canary\":%d}\n", signaling, process_info, task_port, keychain_service, args_readable, env_canary);
    free(args);
    return 0;
}
""")
            compiled = subprocess.run(
                [
                    "/usr/bin/xcrun",
                    "clang",
                    str(c_probe),
                    "-o",
                    str(source / "process-probe"),
                ],
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            outside_process = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(60)"], env=environment
            )

            def stop_helper():
                outside_process.terminate()
                outside_process.wait(timeout=2)

            self.addCleanup(stop_helper)
            region = shared_memory.SharedMemory(create=True, size=32)
            region.buf[:16] = b"synthetic-canary"
            self.addCleanup(region.unlink)
            self.addCleanup(region.close)
            baseline = json.loads(
                subprocess.check_output(
                    [str(source / "process-probe"), str(outside_process.pid)]
                )
            )
            self.assertEqual(baseline["signal"], 1)
            self.assertEqual(baseline["process_info"], 1)
            self.assertEqual(baseline["args_readable"], 1)
            self.assertEqual(baseline["env_canary"], 1)
            sandbox_source = Path(
                os.environ.get(
                    "ALAMODE_SANDBOX_RUNNER_SOURCE", MODULE.with_name("sandbox.mjs")
                )
            ).read_text()
            sandbox_source = sandbox_source.replace(
                "@sandboxRuntime@", os.environ["ALAMODE_SANDBOX_RUNTIME"]
            )
            Path(config["sandboxRunner"]).write_text(sandbox_source)
            outside = home / "synthetic-credential"
            outside.write_text(KEY)
            # The state root comes first: the sibling workspace is planted
            # beneath it, and its mkdir(parents=True) would otherwise create
            # the root this mkdir expects to make.
            control = home / ".local/state/alamode"
            control.mkdir(parents=True, mode=0o700)
            (control / "canary").write_text("trusted control fixture")
            sibling = home / ".local/state/alamode/workspaces/sibling"
            sibling.mkdir(parents=True, mode=0o700)
            sibling.parent.chmod(0o700)
            (sibling / "canary").write_text("sibling fixture")
            approved = root / "approved"
            approved.write_text("approved fixture")
            provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
            provider.daemon_threads = True
            provider.calls = []
            threading.Thread(target=provider.serve_forever, daemon=True).start()
            other = socket.socket()
            other.bind(("127.0.0.1", 0))
            other.listen()
            catalog = {
                "providers": {
                    "fixture": {
                        "api": "openai-completions",
                        "baseUrl": f"http://127.0.0.1:{provider.server_port}/v1",
                        "apiKey": "$PI_PROVIDER_SECRET",
                        "models": [{"id": "probe", "maxTokens": 1024}],
                    }
                }
            }
            Path(config["catalogFile"]).write_text(json.dumps(catalog))
            config_file = root / "config.json"
            config_file.write_text(json.dumps(config))
            probe = """import hashlib,json,os,pathlib,socket,subprocess
r={}
def readable(path):
    try: pathlib.Path(path).read_bytes(); return True
    except OSError: return False
def writable(path):
    try: pathlib.Path(path).write_text("unexpected"); return True
    except OSError: return False
def connects(port):
    try: s=socket.create_connection(("127.0.0.1",port),timeout=.5); s.close(); return True
    except OSError: return False
r["credential_env"]=os.environ.get("PI_PROVIDER_SECRET") is not None
r["credential_config"]=hashlib.sha256(json.loads(pathlib.Path(os.environ["PI_CODING_AGENT_DIR"],"models.json").read_text())["providers"]["fixture"]["apiKey"].encode()).hexdigest()==SYNTHETIC_KEY_HASH
r["credential_file"]=readable(OUTSIDE)
r["sibling"]=readable(SIBLING)
r["source"]=readable(SOURCE)
r["temp_canary"]=readable(TEMP_CANARY)
r["process_access"]=json.loads(subprocess.check_output(["./process-probe",str(HOST_PID)]))
try:
    from multiprocessing import shared_memory
    region=shared_memory.SharedMemory(name=SHM_NAME,create=False)
    r["shared_memory"]=bytes(region.buf[:16])==b"synthetic-canary"
    region.close()
except OSError: r["shared_memory"]=False
r["control"]=readable(CONTROL)
r["outside_write"]=writable(OUTSIDE+".written")
r["approved"]=readable(APPROVED)
r["other_loopback"]=connects(OTHER_PORT)
r["upstream_direct"]=connects(UPSTREAM_PORT)
pathlib.Path("agent.txt").write_text("agent fixture")
a=subprocess.run(["git","add","agent.txt"],capture_output=True)
c=subprocess.run(["git","commit","-m","Synthetic agent commit"],capture_output=True)
r["commit"]=a.returncode==0 and c.returncode==0
r["commit_error"]=c.stderr.decode()
print(json.dumps(r))
"""
            replacements = {
                "SYNTHETIC_KEY_HASH": hashlib.sha256(KEY.encode()).hexdigest(),
                "TEMP_CANARY": temp_canary.name,
                "HOST_PID": outside_process.pid,
                "SHM_NAME": region.name,
                "OUTSIDE": str(outside),
                "SIBLING": str(sibling / "canary"),
                "SOURCE": str(source / "original.txt"),
                "CONTROL": str(control / "canary"),
                "APPROVED": str(approved),
                "OTHER_PORT": other.getsockname()[1],
                "UPSTREAM_PORT": provider.server_port,
            }
            for name, value in replacements.items():
                probe = probe.replace(name, repr(value))
            provider.command = shlex.quote(sys.executable) + " -c " + shlex.quote(probe)
            try:
                for web in (False, True):
                    provider.calls = []
                    command = [
                        sys.executable,
                        str(MODULE),
                        str(config_file),
                        "/fixture/alamode",
                        "--allow-read",
                        str(approved),
                    ]
                    if web:
                        command.append("--web")
                    command += [
                        "--",
                        "--model",
                        "fixture/probe",
                        "--no-session",
                        "--mode",
                        "json",
                        "Run the fixture",
                    ]
                    result = subprocess.run(
                        command,
                        cwd=source,
                        env=environment,
                        capture_output=True,
                        text=True,
                        timeout=30,
                    )
                    self.assertEqual(
                        result.returncode, 0, result.stdout + result.stderr
                    )
                    self.assertGreaterEqual(
                        len(provider.calls), 2, result.stdout + result.stderr
                    )
                    self.assertTrue(
                        all(
                            headers.get("authorization", headers.get("Authorization"))
                            == "Bearer " + KEY
                            for headers, _ in provider.calls
                        )
                    )
                    tools = [
                        message
                        for message in provider.calls[-1][1]["messages"]
                        if message["role"] == "tool"
                    ]
                    report = json.loads(tools[-1]["content"])
                    with self.subTest(web=web):
                        self.assertEqual(
                            report,
                            {
                                "credential_env": False,
                                "credential_config": False,
                                "credential_file": False,
                                "sibling": False,
                                "source": False,
                                "control": False,
                                "temp_canary": False,
                                "shared_memory": False,
                                "process_access": {
                                    "signal": 0,
                                    "process_info": 0,
                                    "task_port": 0,
                                    "securityd": 0,
                                    "args_readable": 0,
                                    "env_canary": 0,
                                },
                                "outside_write": False,
                                "approved": True,
                                "other_loopback": False,
                                "upstream_direct": False,
                                "commit": True,
                                "commit_error": "",
                            },
                            report,
                        )
                    identity = result.stderr.split("alamode: session ", 1)[
                        1
                    ].splitlines()[0]
                    exported = []
                    for _ in range(2):
                        result = subprocess.run(
                            [
                                sys.executable,
                                str(MODULE),
                                str(config_file),
                                "/fixture/alamode",
                                "sessions",
                                "export",
                                identity,
                            ],
                            cwd=source,
                            env=environment,
                            capture_output=True,
                            text=True,
                            timeout=20,
                        )
                        self.assertEqual(
                            result.returncode, 0, result.stdout + result.stderr
                        )
                        exported.append(json.loads(result.stdout))
                    self.assertNotEqual(exported[0]["bundle"], exported[1]["bundle"])
                    receiver = root / ("receiver-web" if web else "receiver-strict")
                    subprocess.run(
                        ["git", "init", "-q", "--bare", str(receiver)],
                        env=environment,
                        check=True,
                    )
                    imported = subprocess.run(
                        [
                            "git",
                            "--git-dir=" + str(receiver),
                            "fetch",
                            exported[0]["bundle"],
                            exported[0]["ref"] + ":refs/heads/result",
                        ],
                        env=environment,
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(imported.returncode, 0, imported.stderr)
                    self.assertEqual((source / "original.txt").read_text(), "fixture\n")
                    self.assertFalse((source / "agent.txt").exists())
            finally:
                provider.shutdown()
                provider.server_close()
                other.close()


if __name__ == "__main__":
    unittest.main()
