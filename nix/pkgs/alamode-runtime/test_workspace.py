import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "workspace", Path(__file__).with_name("workspace.py")
)
workspace = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(workspace)


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pi-workspace-test-")
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.env = workspace._environment()
        self.git(self.source, "init", "-q", "-b", "main")
        (self.source / ".gitattributes").write_text("*.sec filter=git-crypt\n")
        (self.source / "protected.sec").write_bytes(
            b"\0GITCRYPT\0synthetic ciphertext\n"
        )
        (self.source / "plain.txt").write_text("original\n")
        self.git(self.source, "add", ".")
        self.git(self.source, "commit", "-qm", "Fixture baseline")
        self.base = self.git(self.source, "rev-parse", "HEAD").stdout.strip()

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, where, *args, check=True):
        result = subprocess.run(
            [
                workspace.GIT,
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "core.fsmonitor=false",
                "-c",
                "commit.gpgsign=false",
                "-C",
                str(where),
                *args,
            ],
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def create(self, name="session"):
        return workspace.create(self.source, self.root / name, "agent")

    def proposal(self, manifest, text="agent change\n"):
        work = Path(manifest["workspace"])
        (work / "plain.txt").write_text(text)
        self.git(work, "add", "plain.txt")
        self.git(work, "commit", "-qm", "Agent change")
        tip = self.git(work, "rev-parse", "HEAD").stdout.strip()
        bundle = work / "result.bundle"
        self.git(
            work,
            "bundle",
            "create",
            str(bundle),
            manifest["snapshot_commit"] + "..HEAD",
        )
        return tip, bundle

    def test_private_bare_cold_index_and_protected_staging(self):
        manifest = self.create()
        work = Path(manifest["workspace"])
        bare = Path(manifest["common_dir"])
        self.assertTrue(bare.is_dir())
        self.assertTrue((work / ".git").is_file())
        self.assertFalse((work / "protected.sec").exists())
        self.assertFalse((bare / "objects/info/alternates").exists())
        self.assertFalse(any(bare.rglob("git-crypt")))
        self.assertEqual(
            self.git(
                work, "config", "--get", "filter.git-crypt.required"
            ).stdout.strip(),
            "true",
        )
        self.proposal(manifest)
        (Path(manifest["git_dir"]) / "index").unlink()
        self.git(work, "reset", "--mixed", "HEAD")
        self.proposal(manifest, "after index rebuild\n")
        (work / "protected.sec").write_text("unauthorized plaintext\n")
        self.assertNotEqual(
            self.git(work, "add", "--sparse", "protected.sec", check=False).returncode,
            0,
        )
        self.assertEqual(
            self.git(self.source, "rev-parse", "main").stdout.strip(), self.base
        )
        source_inodes = {
            (p.stat().st_dev, p.stat().st_ino)
            for p in (self.source / ".git/objects").rglob("*")
            if p.is_file()
        }
        child_inodes = {
            (p.stat().st_dev, p.stat().st_ino)
            for p in (bare / "objects").rglob("*")
            if p.is_file()
        }
        self.assertFalse(source_inodes & child_inodes)

    def test_branch_checks_out_again_after_a_detach(self):
        manifest = self.create()
        work = Path(manifest["workspace"])
        self.git(work, "checkout", "-q", "--detach")
        self.git(work, "checkout", "-q", manifest["branch"])
        self.assertEqual(
            self.git(
                Path(manifest["common_dir"]), "rev-parse", "--is-bare-repository"
            ).stdout.strip(),
            "true",
        )

    def test_empty_workspace_commits_and_admits_without_importing_nearby_files(self):
        external = self.root / "external-private-fixture"
        external.write_text("synthetic private file outside workspace\n")
        record = self.root / "empty-record"
        manifest = workspace.create_empty(
            self.root / "empty-session", "agent", record_root=record
        )
        work = Path(manifest["workspace"])
        self.assertIsNone(manifest["source"])
        self.assertEqual(manifest["source_base"], manifest["snapshot_commit"])
        self.assertEqual(manifest["record_root"], str(record))
        self.assertEqual(manifest["protected_paths"], [])
        self.assertEqual(self.git(work, "ls-files").stdout, "")
        self.assertEqual({path.name for path in work.iterdir()}, {".git"})
        self.assertEqual(
            self.git(work, "rev-list", "--count", "HEAD").stdout.strip(), "1"
        )
        tip, bundle = self.proposal(manifest)
        admitted = workspace.admit_bundle(
            manifest, bundle, self.root / "empty-quarantine", tip, "empty-proposal"
        )
        child = workspace.create_from_admitted(
            admitted, self.root / "empty-child", "child"
        )
        self.assertEqual(child["snapshot_commit"], tip)
        self.assertEqual(
            self.git(Path(child["workspace"]), "ls-files").stdout, "plain.txt\n"
        )
        self.assertFalse((work / external.name).exists())
        self.assertEqual(
            external.read_text(), "synthetic private file outside workspace\n"
        )

    def test_dirty_snapshot_does_not_execute_source_configuration(self):
        marker = self.root / "executed"
        monitor = self.root / "monitor"
        monitor.write_text(
            "#!/bin/bash\nset -euo pipefail\ntouch '" + str(marker) + "'\n"
        )
        monitor.chmod(0o700)
        self.git(self.source, "config", "core.fsmonitor", str(monitor))
        self.git(self.source, "config", "filter.fixture.clean", str(monitor))
        with (self.source / ".gitattributes").open("a") as stream:
            stream.write("*.txt filter=fixture\n")
        (self.source / "plain.txt").write_text("dirty tracked\n")
        (self.source / "untracked.txt").write_text("new\n")
        (self.source / "link").symlink_to("../outside")
        (self.source / "protected.sec").write_text("decrypted synthetic source\n")
        (self.source / "new.sec").write_text("new protected synthetic source\n")
        manifest = self.create()
        work = Path(manifest["workspace"])
        self.assertFalse(marker.exists())
        self.assertEqual((work / "plain.txt").read_text(), "dirty tracked\n")
        self.assertEqual((work / "untracked.txt").read_text(), "new\n")
        self.assertEqual(os.readlink(work / "link"), "../outside")
        self.assertNotEqual(manifest["snapshot_commit"], self.base)
        self.assertIn("protected.sec", manifest["omitted_working_paths"])
        self.assertIn("new.sec", manifest["omitted_working_paths"])
        self.assertFalse((work / "new.sec").exists())
        self.assertEqual(
            self.git(work, "show", "HEAD:protected.sec").stdout,
            "\0GITCRYPT\0synthetic ciphertext\n",
        )

    def test_source_global_and_default_ignore_files_remain_effective(self):
        home = self.root / "synthetic-home"
        home.mkdir()
        excludes = home / "global-ignore"
        excludes.write_text("private-cache\n")
        (home / ".gitconfig").write_text(
            "[core]\n\texcludesFile = " + str(excludes) + "\n"
        )
        (self.source / "private-cache").write_text("synthetic credential")
        with patch.dict(os.environ, {"HOME": str(home)}, clear=False):
            manifest = self.create("custom-global")
        self.assertFalse((Path(manifest["workspace"]) / "private-cache").exists())
        (home / ".gitconfig").unlink()
        ignore = home / ".config/git/ignore"
        ignore.parent.mkdir(parents=True)
        ignore.write_text("private-cache\n")
        with patch.dict(os.environ, {"HOME": str(home)}, clear=False):
            manifest = self.create("default-global")
        self.assertFalse((Path(manifest["workspace"]) / "private-cache").exists())

    def test_dirty_snapshot_honors_new_attributes_excludes_and_staged_files(self):
        (self.source / ".git/info/exclude").write_text("ignored.txt\n")
        (self.source / "ignored.txt").write_text("must stay outside snapshot\n")
        (self.source / ".gitignore").write_text("staged.txt\n")
        (self.source / "staged.txt").write_text("explicitly staged\n")
        self.git(self.source, "add", "--force", "staged.txt")
        with (self.source / ".gitattributes").open("a") as stream:
            stream.write("*.private filter=git-crypt\n")
        (self.source / "new.private").write_text("new protected contents\n")
        manifest = self.create()
        work = Path(manifest["workspace"])
        self.assertFalse((work / "ignored.txt").exists())
        self.assertFalse((work / "new.private").exists())
        self.assertEqual((work / "staged.txt").read_text(), "explicitly staged\n")
        self.assertIn("new.private", manifest["omitted_working_paths"])

    def test_children_use_only_trusted_snapshots_and_admitted_objects(self):
        manifest = self.create()
        tip, bundle = self.proposal(manifest)
        child = workspace.create_from_snapshot(
            manifest, self.root / "initial-child", "first"
        )
        self.assertEqual(
            (Path(child["workspace"]) / "plain.txt").read_text(), "original\n"
        )
        admitted = workspace.admit_bundle(
            manifest, bundle, self.root / "quarantine", tip, "request-1"
        )
        (Path(manifest["common_dir"]) / "config").write_text(
            "intentionally invalid configuration\n"
        )
        child = workspace.create_from_admitted(
            admitted, self.root / "changed-child", "second"
        )
        self.assertEqual(child["snapshot_commit"], tip)
        self.assertEqual(
            (Path(child["workspace"]) / "plain.txt").read_text(), "agent change\n"
        )
        self.assertFalse((Path(child["workspace"]) / "protected.sec").exists())

    def test_admission_ignores_worker_metadata(self):
        manifest = self.create()
        tip, bundle = self.proposal(manifest)
        marker = self.root / "executed"
        command = "!touch '" + str(marker) + "'"
        self.git(Path(manifest["workspace"]), "config", "core.fsmonitor", command)
        self.git(Path(manifest["workspace"]), "config", "diff.external", command)
        admitted = workspace.admit_bundle(
            manifest, bundle, self.root / "quarantine", tip, "request-1"
        )
        self.assertEqual(admitted["tip"], tip)
        self.assertEqual(admitted["commits"], 1)
        self.assertFalse(marker.exists())
        self.assertTrue(Path(admitted["bundle"]).is_file())

    def test_admission_refuses_trust_gated_agent_configuration(self):
        # Configuration the human's own unsandboxed agents load as executable
        # must never ride a bundle into trusted storage, in any casing and at
        # any depth, because project trust covers the human's checkout once
        # merged.
        for index, path in enumerate(
            (
                ".pi/mcp.json",
                ".PI/settings.json",
                ".Pi/extensions/evil.ts",
                "deep/.pi/nested.txt",
                ".mcp.json",
                ".MCP.Json",
                ".claude/settings.json",
                ".CLAUDE/Settings.local.json",
            )
        ):
            with self.subTest(path=path):
                manifest = self.create(f"gate-session-{index}")
                work = Path(manifest["workspace"])
                target = work / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("{}\n")
                self.git(work, "add", ".")
                self.git(work, "commit", "-qm", "Plant")
                tip = self.git(work, "rev-parse", "HEAD").stdout.strip()
                bundle = work / "result.bundle"
                self.git(
                    work,
                    "bundle",
                    "create",
                    str(bundle),
                    manifest["snapshot_commit"] + "..HEAD",
                )
                with self.assertRaisesRegex(
                    workspace.WorkspaceError, "protected content"
                ):
                    workspace.admit_bundle(
                        manifest,
                        bundle,
                        self.root / f"gate-quarantine-{index}",
                        tip,
                        "gate-proposal",
                    )

    def test_admission_records_context_files(self):
        # Steering-only files ride admission as a recorded warning: pi loads
        # AGENTS.md and CLAUDE.md with no trust decision, and the human's
        # other agents read .claude and .agents the same way, so a merge that
        # carries them must say which paths are model-authored. Claude Code
        # loads CLAUDE.local.md as project memory the same way.
        manifest = self.create("context-session")
        work = Path(manifest["workspace"])
        for path in (
            "AGENTS.md",
            "CLAUDE.md",
            "CLAUDE.local.md",
            ".claude/rules/x.md",
            ".agents/skills/y.md",
        ):
            target = work / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("planted guidance\n")
        self.git(work, "add", ".")
        self.git(work, "commit", "-qm", "Agent change")
        tip = self.git(work, "rev-parse", "HEAD").stdout.strip()
        bundle = work / "result.bundle"
        self.git(
            work,
            "bundle",
            "create",
            str(bundle),
            manifest["snapshot_commit"] + "..HEAD",
        )
        admitted = workspace.admit_bundle(
            manifest, bundle, self.root / "context-quarantine", tip, "ctx-1"
        )
        self.assertEqual(
            admitted["context_files"],
            [
                ".agents/skills/y.md",
                ".claude/rules/x.md",
                "AGENTS.md",
                "CLAUDE.local.md",
                "CLAUDE.md",
            ],
        )

    def test_admission_refuses_case_variant_attribute_files(self):
        # APFS resolves .GITATTRIBUTES to the same file as .gitattributes,
        # and git honors the case variant: measured, an eol rule planted as
        # .GITATTRIBUTES normalized content at add. Every spelling must hit
        # the same refusal as exact case, and .GIT-CRYPT/ key paths are
        # protected content in any casing.
        for index, path in enumerate(
            (".GITATTRIBUTES", ".GitAttributes", ".GIT-CRYPT/keys/default")
        ):
            with self.subTest(path=path):
                manifest = self.create(f"attr-session-{index}")
                work = Path(manifest["workspace"])
                if path.endswith("keys/default"):
                    target = work / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text("planted key material\n")
                    self.git(work, "add", "--", path)
                else:
                    # A working-tree write would collide with the tracked
                    # .gitattributes on APFS, so the variant enters the
                    # index directly, as a planted tree entry.
                    blob = self.git(work, "rev-parse", "HEAD:plain.txt").stdout.strip()
                    self.git(
                        work,
                        "update-index",
                        "--add",
                        "--cacheinfo",
                        "100644",
                        blob,
                        path,
                    )
                self.git(work, "commit", "-qm", "Plant")
                tip = self.git(work, "rev-parse", "HEAD").stdout.strip()
                bundle = work / "result.bundle"
                self.git(
                    work,
                    "bundle",
                    "create",
                    str(bundle),
                    manifest["snapshot_commit"] + "..HEAD",
                )
                with self.assertRaisesRegex(
                    workspace.WorkspaceError, "protected content"
                ):
                    workspace.admit_bundle(
                        manifest,
                        bundle,
                        self.root / f"attr-quarantine-{index}",
                        tip,
                        "gate-proposal",
                    )

    def test_source_head_refuses_planted_symlinks(self):
        # _source_head also resolves a session's private storage on export,
        # a directory the session itself can write. A planted symlink must
        # be refused rather than followed: reading through it would turn a
        # host-side read into a read of an arbitrary file outside the root.
        elsewhere = self.root / "elsewhere"
        elsewhere.write_text("not a ref\n")
        own = self.source / ".git"

        head = own / "HEAD"
        head.unlink()
        head.symlink_to(elsewhere)
        with self.assertRaisesRegex(workspace.WorkspaceError, "symlink"):
            workspace._source_head(own, own)
        head.unlink()
        head.write_text("ref: refs/heads/main\n")

        ref = own / "refs" / "heads" / "main"
        ref.unlink()
        ref.symlink_to(elsewhere)
        with self.assertRaisesRegex(workspace.WorkspaceError, "symlink"):
            workspace._source_head(own, own)
        ref.unlink()
        ref.write_text(self.base + "\n")

        # A missing loose ref falls back to packed-refs, which is refused as
        # a symlink too, not read through.
        subprocess.run(
            [workspace.GIT, "-C", str(self.source), "pack-refs", "--all"],
            env=self.env,
            check=True,
        )
        packed = own / "packed-refs"
        packed.unlink()
        packed.symlink_to(elsewhere)
        with self.assertRaisesRegex(workspace.WorkspaceError, "symlink"):
            workspace._source_head(own, own)

    def test_intermediate_protected_change_is_rejected(self):
        manifest = self.create()
        work = Path(manifest["workspace"])
        blob = (
            subprocess.run(
                [workspace.GIT, "-C", str(work), "hash-object", "-w", "--stdin"],
                input=b"synthetic unauthorized content",
                capture_output=True,
                env=self.env,
                check=True,
            )
            .stdout.decode()
            .strip()
        )
        self.git(
            work,
            "update-index",
            "--add",
            "--cacheinfo",
            "100644",
            blob,
            "protected.sec",
        )
        self.git(work, "commit", "-qm", "Unauthorized intermediate change")
        baseline_blob = self.git(
            work, "rev-parse", manifest["snapshot_commit"] + ":protected.sec"
        ).stdout.strip()
        self.git(
            work,
            "update-index",
            "--cacheinfo",
            "100644",
            baseline_blob,
            "protected.sec",
        )
        self.git(work, "commit", "-qm", "Restore protected path")
        tip, bundle = self.proposal(manifest)
        with self.assertRaisesRegex(workspace.WorkspaceError, "protected"):
            workspace.admit_bundle(
                manifest, bundle, self.root / "quarantine", tip, "request-1"
            )

    def test_bundle_paths_limits_and_root_identity(self):
        manifest = self.create()
        tip, bundle = self.proposal(manifest)
        link = bundle.with_name("link.bundle")
        link.symlink_to(bundle)
        with self.assertRaises(workspace.WorkspaceError):
            workspace.admit_bundle(
                manifest, link, self.root / "q-link", tip, "request-1"
            )
        parent_link = Path(manifest["workspace"]) / "parent-link"
        parent_link.symlink_to(bundle.parent, target_is_directory=True)
        with self.assertRaises(workspace.WorkspaceError):
            workspace.admit_bundle(
                manifest,
                parent_link / bundle.name,
                self.root / "q-parent",
                tip,
                "request-2",
            )
        with self.assertRaisesRegex(workspace.WorkspaceError, "at most"):
            workspace.admit_bundle(
                manifest, bundle, self.root / "q-limit", tip, "request-3", max_bytes=1
            )
        manifest["root_identity"] = [0, 0]
        with self.assertRaisesRegex(workspace.WorkspaceError, "replaced"):
            workspace.admit_bundle(
                manifest, bundle, self.root / "q-root", tip, "request-4"
            )

    def test_mutation_during_handoff_is_rejected(self):
        manifest = self.create()
        tip, bundle = self.proposal(manifest)
        real_fstat = os.fstat
        calls = 0

        def change_after_first_read(descriptor):
            nonlocal calls
            info = real_fstat(descriptor)
            calls += 1
            if calls == 1:
                with bundle.open("ab") as stream:
                    stream.write(b"changed")
            return info

        with patch.object(workspace.os, "fstat", side_effect=change_after_first_read):
            with self.assertRaisesRegex(
                workspace.WorkspaceError, "changed during handoff"
            ):
                workspace.admit_bundle(
                    manifest, bundle, self.root / "quarantine", tip, "request-1"
                )

    def test_attribute_and_new_protected_changes_are_rejected(self):
        for change in ("attributes", "new-protected", "protected-rename"):
            with self.subTest(change=change):
                manifest = self.create(change)
                work = Path(manifest["workspace"])
                if change == "attributes":
                    (work / ".gitattributes").write_text("")
                    self.git(work, "add", ".gitattributes")
                elif change == "new-protected":
                    blob = self.git(work, "rev-parse", "HEAD:plain.txt").stdout.strip()
                    self.git(
                        work,
                        "update-index",
                        "--add",
                        "--cacheinfo",
                        "100644",
                        blob,
                        "new.sec",
                    )
                else:
                    blob = self.git(
                        work, "rev-parse", "HEAD:protected.sec"
                    ).stdout.strip()
                    self.git(work, "update-index", "--force-remove", "protected.sec")
                    self.git(
                        work,
                        "update-index",
                        "--add",
                        "--cacheinfo",
                        "100644",
                        blob,
                        "renamed.txt",
                    )
                self.git(work, "commit", "-qm", "Unauthorized policy change")
                tip, bundle = self.proposal(manifest)
                with self.assertRaisesRegex(workspace.WorkspaceError, "protected"):
                    workspace.admit_bundle(
                        manifest,
                        bundle,
                        self.root / (change + "-quarantine"),
                        tip,
                        "request-1",
                    )


if __name__ == "__main__":
    unittest.main()
