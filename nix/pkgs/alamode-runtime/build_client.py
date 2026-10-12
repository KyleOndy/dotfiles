import base64
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import request


def snapshot(config, temporary):
    work = Path(config["workspace"])
    env = {
        key: value for key, value in os.environ.items() if not key.startswith("GIT_")
    }
    env.update(
        GIT_CONFIG_NOSYSTEM="1",
        GIT_CONFIG_GLOBAL="/dev/null",
        GIT_TERMINAL_PROMPT="0",
        GIT_AUTHOR_NAME="alamode build",
        GIT_AUTHOR_EMAIL="alamode-build@localhost",
        GIT_COMMITTER_NAME="alamode build",
        GIT_COMMITTER_EMAIL="alamode-build@localhost",
    )

    def git(args, *, export=False, data=None):
        flags = (
            ["--git-dir=" + str(temporary / "export.git"), "--work-tree=" + str(work)]
            if export
            else ["-C", str(work)]
        )
        result = subprocess.run(
            [
                "git",
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "core.fsmonitor=false",
                *flags,
                *args,
            ],
            input=data,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            timeout=120,
        )
        if result.returncode:
            raise ValueError(result.stderr.decode(errors="replace")[-4000:])
        return result.stdout.decode().strip()

    head = git(["rev-parse", "HEAD"])
    objects = git(["rev-parse", "--path-format=absolute", "--git-path", "objects"])
    git(["init", "--bare", "--quiet", str(temporary / "export.git")])
    env["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = objects
    env["GIT_INDEX_FILE"] = str(temporary / "index")
    git(["read-tree", head], export=True)
    excluded = [":(exclude,literal)" + path for path in config["protected_paths"]]
    git(["add", "--all", "--", ".", *excluded], export=True)
    tree = git(["write-tree"], export=True)
    tip = git(
        ["commit-tree", tree, "-p", head],
        export=True,
        data=b"Snapshot working files for isolated build\n",
    )
    git(["update-ref", "refs/heads/build", tip], export=True)
    git(["symbolic-ref", "HEAD", "refs/heads/build"], export=True)
    bundle = temporary / "source.bundle"
    git(["bundle", "create", str(bundle), "HEAD"], export=True)
    return bundle, tip


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if args and args[0] == "nix":
        args.pop(0)
    if not args or args[0] not in ("build", "eval"):
        raise ValueError(
            "This session's nix command supports isolated build and eval only"
        )
    config = json.loads(Path(os.environ["ALAMODE_BUILD_CLIENT"]).read_text())
    job = uuid.uuid4().hex

    def interrupted(*_):
        raise KeyboardInterrupt

    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)

    def call(op, **fields):
        result = request(
            config["socket"],
            config["token"],
            {"op": op, "id": job, **fields},
            timeout=150,
        )
        if result.get("receipt") in ("failed", "uncertain"):
            raise ValueError(
                result.get("error")
                or result.get("message", "Build request needs reconciliation")
            )
        return result

    try:
        with tempfile.TemporaryDirectory(prefix="alamode-build-") as directory:
            bundle, tip = snapshot(config, Path(directory))
            call("start", bundle=str(bundle), tip=tip, args=args)
        offset = stderr_offset = 0
        while True:
            result = call("status", offset=offset, stderr_offset=stderr_offset)
            if result["output"]:
                sys.stdout.buffer.write(
                    base64.b64decode(result["output"], validate=True)
                )
                sys.stdout.buffer.flush()
            if result["stderr"]:
                sys.stderr.buffer.write(
                    base64.b64decode(result["stderr"], validate=True)
                )
                sys.stderr.buffer.flush()
            offset = result["offset"]
            stderr_offset = result["stderr_offset"]
            if (
                result["state"] in ("completed", "failed", "cancelled", "lost")
                and not result["more"]
            ):
                if result.get("error"):
                    print("alamode build: " + result["error"], file=sys.stderr)
                print("alamode build record: " + result["record"], file=sys.stderr)
                return result.get("returncode", 1)
            time.sleep(0.2)
    except KeyboardInterrupt:
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(signum, signal.SIG_IGN)
        try:
            call("cancel")
        except Exception as error:
            print(
                f"alamode build: cancellation uncertain for {job}: {error}",
                file=sys.stderr,
            )
        return 130


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"alamode build: {error}", file=sys.stderr)
        sys.exit(1)
