import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch


MODULE = Path(
    os.environ.get("PI_SESSION_MODULE", Path(__file__).with_name("session.py"))
)
sys.path.insert(0, str(MODULE.parent.parent / "pi-broker"))
spec = importlib.util.spec_from_file_location("pi_session", MODULE)
session = importlib.util.module_from_spec(spec)
spec.loader.exec_module(session)
KEY = "synthetic-provider-key-never-in-child"


def configuration(root):
    return {
        "pi": os.environ.get("PI_TEST_BIN", "pi"),
        "node": os.environ.get("PI_NODE", "node"),
        "shell": os.environ.get("PI_BASH", "/bin/bash"),
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
        "broker": "",
        "seatsFile": "",
        "trustedProviders": [],
        "settingsFile": "",
        "runtimeSource": "",
        "gitName": "Synthetic Pi",
        "gitEmail": "synthetic@example.invalid",
        "resolvers": {},
        "resolverGates": {},
        "catalogFile": str(root / "catalog.json"),
        "relayModule": os.environ.get(
            "PI_RELAY_MODULE", str(MODULE.parent.parent / "pi-provider-relay/relay.py")
        ),
        "sandboxRunner": str(root / "sandbox.mjs"),
        "privateProviderHosts": ["127.0.0.1"],
    }


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pi-session-policy-")
        self.root = Path(self.temporary.name)
        self.config = configuration(self.root)
        self.work = self.root / "session"
        self.work.mkdir(mode=0o700)
        self.records = self.root / "control"
        self.records.mkdir(mode=0o700)
        options, _ = session.parse([], self.config)
        self.manifest = {
            "id": "fixture",
            "policy": session.policy(options, self.config, self.root),
            "seats": {"PI_SESSION_MODEL": "fixture/probe"},
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
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            session.parse(
                ["--resume-session", "first", "--export-session", "second"], self.config
            )
        self.assertEqual(error.exception.code, 2)
        for args in (
            ["--resume-session", "fixture", "--web"],
            ["--coordinator", "fixture", "--allow-registry"],
            ["--coordinator", "fixture", "--allow-trustd"],
            ["--coordinator", "fixture", "--allow-clipboard"],
            ["--allow-nix"],
            ["--no-sandbox"],
            ["--allow-unknown"],
        ):
            with self.subTest(args=args), self.assertRaises(session.SessionError):
                options, _ = session.parse(args, self.config)
                session.policy(options, self.config, self.root)
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
        self.assertTrue(
            {
                str(path) for path in session.transport_directories(self.manifest)
            }.issubset(rules["filesystem"]["denyWrite"])
        )

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
            for flag in ("--help", "--version"):
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(session.main([str(config), "pi", flag]), 0)
                result = json.loads(evidence.read_text())
                self.assertIn(flag, result["args"])
                self.assertIn("--no-extensions", result["args"])
                self.assertNotIn("NODE_OPTIONS", result["env"])
                self.assertNotIn("PROVIDER_API_KEY", result["env"])
                self.assertNotEqual(result["cwd"], str(self.root))

    def test_replaced_workspace_is_rejected_before_execution(self):
        self.work.rename(self.root / "old-session")
        self.work.mkdir(mode=0o700)
        with self.assertRaisesRegex(session.SessionError, "root was replaced"):
            session.execute(
                self.config, self.manifest, ["false"], {}, self.work / "runtime"
            )

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
        import shlex

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
        manifest = {**self.manifest, "workspace": metadata}
        runtime = session.prepare(
            self.config, manifest, type("Relay", (), {"catalog": {"providers": {}}})()
        )
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
        proposal = self.root / "proposal.bundle"
        git(
            work,
            "bundle",
            "create",
            str(proposal),
            "HEAD",
            "^" + metadata["snapshot_commit"],
        )
        canary = self.root / "outside-git-executed"
        with (Path(metadata["common_dir"]) / "config").open("a") as stream:
            stream.write(f"\n[core]\n fsmonitor = touch {canary}\n")

        def contained(_config, _manifest, arguments, environment, _runtime):
            self.assertEqual(_runtime, runtime)
            self.assertEqual(environment["GIT_CONFIG_VALUE_0"], "/dev/null")
            command = shlex.split(arguments[-1])
            shutil.copyfile(proposal, command[3])
            Path(command[-1]).write_text(tip + "\n")
            return 0

        original_git = session.workspace._git

        def trusted_git(directory, *args, **kwargs):
            self.assertNotIn(Path(metadata["session_root"]), Path(directory).parents)
            return original_git(directory, *args, **kwargs)

        exports = []
        with (
            patch.object(session, "execute", side_effect=contained),
            patch.object(session.workspace, "_git", side_effect=trusted_git),
        ):
            for _ in range(2):
                output = io.StringIO()
                with redirect_stdout(output):
                    self.assertEqual(
                        session.export_session(self.config, manifest, self.root), 0
                    )
                exports.append(json.loads(output.getvalue()))
        self.assertNotEqual(exports[0]["bundle"], exports[1]["bundle"])
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
        with self.assertRaises(OSError):
            session.prepare(self.config, self.manifest, Relay())
        self.assertFalse((self.root / "settings.json").exists())

    def test_sandbox_denies_plantable_guard_and_agent_bin_paths(self):
        rules = session.sandbox_policy(
            self.config, self.manifest, self.work / "runtime", 0
        )
        workspace = Path(self.manifest["workspace"]["workspace"])
        expected = {
            session.cased_deny(self.work, workspace / ".pi" / "secret-guard.json"),
            session.cased_deny(self.work, workspace / ".pi" / "verify.json"),
            session.cased_deny(self.work, self.work / "runtime" / "agent" / "bin"),
            session.cased_deny(self.work, self.work / "runtime" / "agent" / "npm"),
        }
        self.assertTrue(
            expected.issubset(set(rules["filesystem"]["denyWrite"])),
            rules["filesystem"]["denyWrite"],
        )
        # APFS resolves names case-insensitively while Seatbelt regexes are
        # case-sensitive, so every variant spelling of every plantable path
        # must still match some deny entry; the character classes guarantee it.
        variants = []
        for name in ("secret-guard.json", "verify.json"):
            for dot_pi in (".pi", ".PI", ".Pi"):
                for worktree in ("worktree", "Worktree"):
                    variants.append(self.work / worktree / dot_pi / name)
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
        ):
            (agent / name).write_text("{}")
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
            "extensions",
            "themes",
            "bin",
            "npm",
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
    os.environ.get("PI_NATIVE_TESTS") == "1" and sys.platform == "darwin",
    "Native Seatbelt integration is opt-in outside the Nix build sandbox",
)
class NativeSessionTests(unittest.TestCase):
    @unittest.skipUnless(
        os.environ.get("PI_BROKER_BIN") and os.environ.get("PI_COORDINATOR_EXTENSION"),
        "Set PI_BROKER_BIN and PI_COORDINATOR_EXTENSION for native coordinator integration",
    )
    def test_real_coordinator_socket_child_and_reconnect(self):
        import shlex
        import uuid

        with tempfile.TemporaryDirectory(
            prefix="pi-coordinator-native-", dir="/private/tmp"
        ) as temporary:
            root = Path(temporary)
            home, source = root / "home", root / "source"
            home.mkdir()
            source.mkdir()
            config = configuration(root)
            config["broker"] = os.environ["PI_BROKER_BIN"]
            config["resolvers"] = {"PI_PROVIDER_SECRET": "printf " + shlex.quote(KEY)}
            config["runtimeSource"] = str(root / "trusted-runtime")
            extensions = Path(config["runtimeSource"]) / "extensions"
            extensions.mkdir(parents=True)
            shutil.copyfile(
                os.environ["PI_COORDINATOR_EXTENSION"], extensions / "coordinator.ts"
            )
            config["systemReadPaths"].append(config["runtimeSource"])
            config["piArgs"] = ["--model", "fixture/probe"]
            Path(config["sandboxRunner"]).write_text(
                Path(
                    os.environ.get(
                        "PI_SANDBOX_RUNNER_SOURCE", MODULE.with_name("sandbox.mjs")
                    )
                )
                .read_text()
                .replace("@sandboxRuntime@", os.environ["PI_SANDBOX_RUNTIME"])
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
                                "command": 'test -z "${PI_PROVIDER_SECRET:-}" && test "$PI_COORD_ROLE" = child && printf child-fixture'
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
            launcher = root / "pi-launcher"
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
                    [str(launcher), "--coordinator", "--mode", "json", "Main fixture"],
                    cwd=source,
                    env=environment,
                    capture_output=True,
                    text=True,
                    timeout=45,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                coords = [
                    path.parent
                    for path in (home / ".local/state/pi-control/coordinators").glob(
                        "*/broker.json"
                    )
                ]
                self.assertEqual(len(coords), 1)
                coord = coords[0]
                credential = json.loads(
                    subprocess.check_output(
                        [config["broker"], "--credentials", str(coord)], env=environment
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
                        "--coordinator=" + coord.name,
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
                        for path in (
                            home / ".local/state/pi-control/coordinators"
                        ).glob("*/broker.json")
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
            prefix="pi-session-native-", dir="/private/tmp"
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
                    "PI_SANDBOX_RUNNER_SOURCE", MODULE.with_name("sandbox.mjs")
                )
            ).read_text()
            sandbox_source = sandbox_source.replace(
                "@sandboxRuntime@", os.environ["PI_SANDBOX_RUNTIME"]
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
                    "/fixture/pi",
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
                prefix="pi-session-native-", dir="/private/tmp"
            ) as temporary,
            tempfile.NamedTemporaryFile(prefix="pi-native-canary-") as temp_canary,
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
                    "PI_SANDBOX_RUNNER_SOURCE", MODULE.with_name("sandbox.mjs")
                )
            ).read_text()
            sandbox_source = sandbox_source.replace(
                "@sandboxRuntime@", os.environ["PI_SANDBOX_RUNTIME"]
            )
            Path(config["sandboxRunner"]).write_text(sandbox_source)
            outside = home / "synthetic-credential"
            outside.write_text(KEY)
            sibling = home / ".local/state/pi-workspaces/sibling"
            sibling.mkdir(parents=True, mode=0o700)
            sibling.parent.chmod(0o700)
            (sibling / "canary").write_text("sibling fixture")
            control = home / ".local/state/pi-control"
            control.mkdir(mode=0o700)
            (control / "canary").write_text("trusted control fixture")
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
                        "/fixture/pi",
                        "--allow-read",
                        str(approved),
                    ]
                    if web:
                        command.append("--web")
                    command += [
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
                    identity = result.stderr.split("pi: session ", 1)[1].splitlines()[0]
                    exported = []
                    for _ in range(2):
                        result = subprocess.run(
                            [
                                sys.executable,
                                str(MODULE),
                                str(config_file),
                                "/fixture/pi",
                                "--export-session",
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
