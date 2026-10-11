import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


class ForgeOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pi-forge-owner-")
        self.root = Path(self.temporary.name)
        source = Path(
            os.environ.get(
                "PI_FORGE_SOURCE", str(Path(__file__).parent.parent / "forge/forge.sh")
            )
        )
        body = source.read_text().split(
            "# cmd_status does not run check_prerequisites", 1
        )[0]
        for token, value in {
            "apiPortBase": "6440",
            "apiPortSpan": "16",
            "cachePortBase": "6420",
            "cachePortSpan": "16",
            "vmConfig": "/fixture/vm.json",
        }.items():
            body = body.replace("@" + token + "@", value)
        self.script = self.root / "forge-fixture"
        self.script.write_text(
            "set -euo pipefail\n"
            + body
            + """
remove_vm() { echo "$INSTANCE" >>"$HOME/removed"; sleep "${FIXTURE_DELAY:-0}"; }
case "$1" in
claim) cmd_claim "$2" ;;
release) cmd_release "$2" ;;
nuke) cmd_nuke ;;
esac
"""
        )
        self.env = {
            key: os.environ[key] for key in ("PATH", "TMPDIR") if key in os.environ
        }
        self.env["HOME"] = str(self.root)

    def run_forge(self, *args, instance=None, wait=True, delay=None):
        env = dict(self.env)
        if instance:
            env["FORGE_INSTANCE"] = str(instance)
        if delay:
            env["FIXTURE_DELAY"] = str(delay)
        command = [shutil.which("bash"), str(self.script), *args]
        if not wait:
            return subprocess.Popen(
                command,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        return subprocess.run(
            command, env=env, text=True, capture_output=True, timeout=5
        )

    def tearDown(self):
        self.temporary.cleanup()

    def test_changed_owner_and_idempotent_claim(self):
        self.assertEqual(self.run_forge("claim", "lease-alpha").stdout.strip(), "1")
        self.assertEqual(self.run_forge("claim", "lease-alpha").stdout.strip(), "1")
        label = self.root / ".local/state/forge/1/label"
        label.write_text("lease-beta\n")
        refusal = self.run_forge("release", "lease-alpha", instance=1)
        self.assertNotEqual(refusal.returncode, 0)
        self.assertIn("lease changed", refusal.stderr)
        self.assertFalse((self.root / "removed").exists())
        released = self.run_forge("release", "lease-beta", instance=1)
        self.assertEqual(released.returncode, 0, released.stderr)
        self.assertFalse(label.exists())

    def test_claim_waits_for_release_and_nuke(self):
        for operation in ("release", "nuke"):
            self.assertEqual(self.run_forge("claim", "lease-alpha").stdout.strip(), "1")
            args = [operation] + (["lease-alpha"] if operation == "release" else [])
            removing = self.run_forge(*args, instance=1, wait=False, delay=0.3)
            deadline = time.monotonic() + 2
            while not (self.root / "removed").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            started = time.monotonic()
            claimant = self.run_forge("claim", "lease-beta")
            self.assertGreater(time.monotonic() - started, 0.1)
            self.assertEqual(claimant.stdout.strip(), "1", claimant.stderr)
            self.assertEqual(removing.wait(timeout=2), 0)
            removing.communicate()
            self.assertEqual(
                (self.root / ".local/state/forge/1/label").read_text().strip(),
                "lease-beta",
            )
            self.run_forge("release", "lease-beta", instance=1)
            (self.root / "removed").unlink()


if __name__ == "__main__":
    unittest.main()
