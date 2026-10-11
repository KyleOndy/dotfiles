import os
from pathlib import Path
import pwd
import stat
import subprocess
import tempfile
import unittest


class SoftnetInstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pi-softnet-install-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.parent = self.root / "helpers"
        self.target = self.parent / "pi-builder/softnet"
        self.source = self.root / "source"
        self.source.write_bytes(b"fixture version one")

    def run_installer(self, action="install", *, succeeds=True):
        result = subprocess.run(
            [os.environ["PI_SOFTNET_INSTALLER"], action, self.source, self.parent],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode == 0, succeeds, result.stderr)
        return result

    def test_install_upgrade_repair_and_remove(self):
        self.run_installer("remove")
        self.assertFalse(self.parent.exists())
        self.run_installer()
        self.assertEqual(self.target.read_bytes(), self.source.read_bytes())
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o4755)
        self.assertEqual(self.target.stat().st_uid, os.geteuid())
        self.assertEqual(self.target.stat().st_gid, os.getegid())
        first = self.target.stat().st_ino
        self.run_installer()
        self.assertEqual(self.target.stat().st_ino, first)
        self.source.write_bytes(b"fixture version two")
        self.run_installer()
        self.assertEqual(self.target.read_bytes(), self.source.read_bytes())
        self.assertNotEqual(self.target.stat().st_ino, first)
        self.target.chmod(0o755)
        self.run_installer()
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o4755)
        retained = self.target.parent / "operator-note"
        retained.write_text("keep")
        self.run_installer("remove")
        self.assertFalse(self.target.exists())
        self.assertEqual(retained.read_text(), "keep")
        retained.unlink()
        self.run_installer("remove")
        self.assertFalse(self.target.parent.exists())

    def test_invalid_source_preserves_installed_helper(self):
        self.run_installer()
        previous = self.target.read_bytes()
        self.source.unlink()
        self.run_installer(succeeds=False)
        self.assertEqual(self.target.read_bytes(), previous)
        self.assertEqual(list(self.target.parent.glob(".install.*")), [])

    def test_repairs_helper_acl_and_rejects_directory_acl(self):
        self.run_installer()
        commands = Path("/bin")
        entry = f"user:{pwd.getpwuid(os.geteuid()).pw_name} allow write"
        subprocess.run([commands / "chmod", "+a", entry, self.target], check=True)
        before = self.target.stat().st_ino
        self.run_installer()
        self.assertNotEqual(self.target.stat().st_ino, before)
        listing = subprocess.check_output([commands / "ls", "-lde", self.target])
        self.assertEqual(len(listing.splitlines()), 1)
        subprocess.run([commands / "chmod", "+a", entry, self.parent], check=True)
        try:
            self.run_installer(succeeds=False)
            self.assertEqual(self.target.read_bytes(), self.source.read_bytes())
        finally:
            subprocess.run([commands / "chmod", "-N", self.parent], check=True)

    def test_rejects_redirected_or_writable_destinations(self):
        self.run_installer()
        canary = self.root / "canary"
        canary.write_bytes(b"preserve")
        self.target.unlink()
        self.target.symlink_to(canary)
        for action in ("install", "remove"):
            self.run_installer(action, succeeds=False)
            self.assertEqual(canary.read_bytes(), b"preserve")
        self.target.unlink()
        self.target.parent.rmdir()
        self.target.parent.symlink_to(self.root)
        self.run_installer(succeeds=False)
        self.target.parent.unlink()
        self.parent.chmod(0o777)
        self.run_installer(succeeds=False)
        self.parent.chmod(0o755)
        self.parent.rmdir()
        self.parent.symlink_to(self.root)
        self.run_installer(succeeds=False)


if __name__ == "__main__":
    unittest.main()
