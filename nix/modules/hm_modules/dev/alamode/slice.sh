#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
usage: alamode slice <name> | <ticket> [<name>] [GRANTS] [-- PI ARGS]

Makes or reuses the worktree for a task (git wt-start), blocks direnv in it,
and starts alamode in a new window of the worktree's tmux session. Everything
from the first flag on reaches alamode unchanged.

  alamode slice add-starship
  alamode slice DEV-123 --profile work -- --model PROVIDER/ID
EOF
}

case ${1:-} in
-h | --help)
	usage
	exit 0
	;;
'' | -*)
	usage >&2
	exit 1
	;;
esac

worktree=()
while (($#)) && [[ $1 != -* ]]; do
	worktree+=("$1")
	shift
done

path=$(git wt-start "${worktree[@]}")

# alamode lands its commits in this checkout when it quits, and those can
# change flake.nix, whose shellHook direnv would run unsandboxed in any shell
# here once it reloads. deny blocks every reload until `git adopt` allows the
# worktree again.
if [[ -e ${path}/.envrc ]]; then
	direnv deny "$path"
fi

printf -v command '%q ' alamode "$@"
tmux-sessionizer "$path" "${command% }"

echo "alamode slice: alamode is running in a new tmux window at ${path}" >&2
if branch=$(git -C "$path" symbolic-ref --short -q HEAD) &&
	git -C "$path" rev-parse --verify --quiet "refs/wt-base/${branch}" >/dev/null; then
	echo "  review every commit on ${branch}, from any session: git log -p refs/wt-base/${branch}..${branch}" >&2
fi
if [[ -e ${path}/.envrc ]]; then
	echo "  direnv stays blocked there until you review the work and run: git adopt" >&2
fi
