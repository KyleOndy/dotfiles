"""Acceptance fixture for a provisioned native builder, with no human repository input."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import uuid

import builder
import workspace


def check(config):
    fixture = Path(config["record_root"]) / ("native-check-" + uuid.uuid4().hex)
    fixture.mkdir(mode=0o700)
    source = fixture / "source"
    source.mkdir()

    def git(directory, *args):
        return (
            subprocess.check_output(
                [workspace.GIT, "-C", str(directory), *args],
                env=workspace._environment(),
            )
            .decode()
            .strip()
        )

    git(source, "init", "-q", "-b", "main")
    (source / "README").write_text("Native builder synthetic acceptance fixture\n")
    (source / ".gitattributes").write_text("*.sec filter=git-crypt\n")
    (source / "font.sec").write_bytes(b"\0GITCRYPT\0synthetic ciphertext")
    git(source, "add", "README", ".gitattributes", "font.sec")
    git(source, "commit", "-qm", "Fixture baseline")
    manifest = workspace.create(source, fixture / "worker", "check")
    worker = Path(manifest["workspace"])
    (worker / "hello.c").write_text("int main(void) { return 0; }\n")
    (worker / "default.nix").write_text(
        'derivation { name = "pi-native-cold-c-build-'
        + fixture.name
        + '"; system = builtins.currentSystem;\n'
        '  builder = "/bin/sh"; src = ./hello.c; PATH = "/usr/bin:/bin:/usr/sbin:/sbin";\n'
        "  font = builtins.readFile ./font.sec;\n"
        '  args = [ "-euc" '
        + json.dumps('test "$font" = "materialized fixture"; clang $src -o $out; $out')
        + " ];\n"
        '  __sandboxProfile = "(allow file-read* file-write* process-exec)";\n'
        "}\n"
    )
    git(worker, "add", "hello.c", "default.nix")
    git(worker, "commit", "-qm", "Compile native C source in guest")
    tip = git(worker, "rev-parse", "HEAD")
    bundle = worker / "proposal.bundle"
    git(worker, "bundle", "create", str(bundle), manifest["snapshot_commit"] + "..HEAD")
    admitted = workspace.admit_bundle(
        manifest, bundle, fixture / "admitted", tip, "native-check"
    )
    materialized = fixture / "font-input"
    materialized.write_bytes(b"materialized fixture")
    fixture_config = dict(
        config,
        materialized_inputs=[
            {
                "source": str(materialized.resolve()),
                "target": "font.sec",
                "sha256": hashlib.sha256(materialized.read_bytes()).hexdigest(),
            }
        ],
    )
    result = builder.build(
        fixture_config,
        admitted,
        [
            "nix",
            "build",
            "--impure",
            "--no-link",
            "--file",
            "default.nix",
        ],
    )
    report = {
        "status": "pass" if result["status"] == "completed" else "fail",
        "fixture": str(fixture),
        "build": result,
    }
    (fixture / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text())
        report = check(config)
    except (builder.MissingPrerequisite, FileNotFoundError) as error:
        print(json.dumps({"status": "missing-prerequisite", "error": str(error)}))
        return 2
    except (
        builder.BuilderError,
        workspace.WorkspaceError,
        OSError,
        ValueError,
        KeyError,
        subprocess.SubprocessError,
    ) as error:
        print(json.dumps({"status": "fail", "error": str(error)}))
        return 1
    print(json.dumps(report))
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
