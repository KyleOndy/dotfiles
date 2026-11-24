#!/usr/bin/env bash
set -euo pipefail

# Usage: disk-reclaim [report|quick]
#   report  (default) sizes of the places this mac fills up. Changes nothing.
#   quick   drops what a rebuild or re-download restores, then prints the gain.
# What needs judgment (worktrees, ticket clones, alamode sessions, VMs) is the
# disk-reclaim skill's job, not this script's.

readonly DATA_VOLUME=/System/Volumes/Data
TMP=$(getconf DARWIN_USER_TEMP_DIR)
readonly TMP="${TMP%/}"
readonly ALAMODE_ROOTS="${HOME}/.local/state/alamode/gcroots"
readonly HM_CURRENT="${HOME}/.local/state/home-manager/gcroots/current-home"
readonly ENVTEST_BIN='/bin/k8s/[^/]+/(etcd|kube-apiserver)$'

free_kib() { df -k "$DATA_VOLUME" | awk 'NR==2 {print $4}'; }

# Prints "<GiB> <path>" largest first. du counts an APFS clone in full each
# time, so a worktree or VM cloned from another reads larger than it frees.
sizes() {
	{ du -xsk "$@" 2>/dev/null || true; } | sort -rn |
		awk '{k=$1; $1=""; printf "%7.1fG %s\n", k/1048576, substr($0,2)}' |
		sed "s#${HOME}#~#"
}

# Envtest servers whose test process is gone: launchd (pid 1) adopted them.
orphan_envtest_pids() {
	ps -Ao pid=,ppid=,command= | awk -v re="$ENVTEST_BIN" '$2==1 && $3 ~ re {print $1}'
}

# alamode pins each deployment's store paths and leaves older ones for a
# human to prune (pin_store_roots in nix/pkgs/alamode-runtime/session.py).
# Stale means outside the current system and home closures.
stale_alamode_roots() {
	[[ -d $ALAMODE_ROOTS ]] || return 0
	local current
	current=$(mktemp)
	{
		nix-store -qR /run/current-system
		nix-store -qR "$HM_CURRENT"
	} | sort -u >"$current"
	local link
	for link in "$ALAMODE_ROOTS"/*; do
		[[ -L $link ]] || continue
		grep -qxF "$(readlink "$link")" "$current" || echo "$link"
	done
	rm -f "$current"
}

# Worktree directories whose gitdir is missing. A .direnv inside one roots
# store paths, and without the gitdir git cannot show its uncommitted work.
orphan_worktrees() {
	local gitfile gitdir
	while IFS= read -r gitfile; do
		gitdir=$(sed -n 's/^gitdir: //p' "$gitfile")
		[[ $gitdir == /* ]] || gitdir="$(dirname "$gitfile")/${gitdir}"
		if [[ ! -d $gitdir ]]; then dirname "$gitfile"; fi
	done < <(find "${HOME}/src" -mindepth 3 -maxdepth 4 -name .git -type f 2>/dev/null)
}

# Worktrees whose upstream branch was deleted, usually a merged PR. As of the
# last fetch.
gone_worktrees() {
	local bare wt branch
	for bare in "${HOME}"/src/*/*/.bare; do
		[[ -d $bare ]] || continue
		git -C "$bare" worktree list --porcelain |
			awk '/^worktree /{w=substr($0,10)} /^branch /{print w"\t"substr($0,8)}' |
			while IFS=$'\t' read -r wt branch; do
				if [[ $(git -C "$bare" for-each-ref --format='%(upstream:track)' "$branch") == "[gone]" ]]; then
					echo "${wt/#${HOME}/\~}"
				fi
			done
	done
}

report() {
	echo "== free"
	df -h "$DATA_VOLUME" | awk 'NR==2 {print $4" free of "$2}'
	diskutil info /nix | awk -F': *' '/Volume Used Space/ {sub(/ \(.*/, "", $2); print "nix store: "$2}'

	echo "== hotspots"
	local -a paths=(
		"${HOME}"/.local/share/alamode-builder/tart/vms/*
		"${HOME}/.local/share/alamode-builder/tart/cache"
		"${HOME}/.local/state/alamode/workspaces"
		"${HOME}/.local/state/alamode/records"
		"${HOME}"/.lima/forge*
		"${HOME}/.colima"
		"${HOME}"/src/*/*
		"${HOME}/Library/Caches/go-build"
		"${HOME}/go/pkg/mod"
		"${HOME}/.pulumi/plugins"
		"${HOME}/.cache/uv"
		"${HOME}/.cache/huggingface"
		"${HOME}/.kube/cache"
		"${HOME}/.claude/projects"
		"$TMP"
	)
	sizes "${paths[@]}" | awk '$1+0 >= 0.5'

	echo "== ticket clones (~/work/tickets/*/repos, gitignored)"
	sizes "${HOME}"/work/tickets/*/repos | awk 'NR <= 10'

	echo "== counts"
	echo "orphaned envtest processes: $(orphan_envtest_pids | wc -l | tr -d ' ')"
	echo "envtest temp dirs: $(find "$TMP" -maxdepth 1 -name 'k8s_test_framework_*' | wc -l | tr -d ' ')"
	echo "stale alamode gcroots: $(stale_alamode_roots | wc -l | tr -d ' ')"
	echo "nix system generations: $(find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' | wc -l | tr -d ' ')"

	echo "== orphaned worktree dirs"
	orphan_worktrees | sed "s#${HOME}#~#"
	echo "== worktrees with a deleted upstream branch"
	gone_worktrees
}

quick() {
	local before
	before=$(free_kib)

	if command -v go >/dev/null; then go clean -cache; fi
	if command -v golangci-lint >/dev/null; then golangci-lint cache clean; fi
	if command -v uv >/dev/null; then uv cache prune --quiet; fi
	# Base images colima downloaded to create its VM.
	rm -rf "${HOME}/Library/Caches/colima"

	local -a pids
	mapfile -t pids < <(orphan_envtest_pids)
	if ((${#pids[@]})); then
		kill "${pids[@]}" 2>/dev/null || true
		sleep 5
		# A kube-apiserver whose etcd is gone can hang in shutdown on SIGTERM.
		mapfile -t pids < <(orphan_envtest_pids)
		if ((${#pids[@]})); then kill -9 "${pids[@]}" 2>/dev/null || true; fi
	fi
	# A dir named in a live process's arguments belongs to a running test.
	local live dir
	live=$(ps -Ao command=)
	for dir in "$TMP"/k8s_test_framework_*; do
		[[ -d $dir ]] || continue
		grep -qF "$dir" <<<"$live" || rm -rf "$dir"
	done

	local -a stale
	mapfile -t stale < <(stale_alamode_roots)
	local link busy=0
	for link in "${stale[@]}"; do
		if grep -qF "$(readlink "$link")" <<<"$live"; then
			busy=1
			break
		fi
	done
	if ((busy)); then
		echo "kept stale alamode gcroots: a running process uses one"
	elif ((${#stale[@]})); then
		rm -f "${stale[@]}"
		echo "removed ${#stale[@]} stale alamode gcroots"
	fi
	nix-collect-garbage 2>&1 | tail -2 || echo "nix-collect-garbage failed"

	local after
	after=$(free_kib)
	awk -v a="$after" -v b="$before" 'BEGIN {printf "freed %.1fG, %.1fG free\n", (a-b)/1048576, a/1048576}'
}

case "${1:-report}" in
report) report ;;
quick) quick ;;
*)
	echo "usage: disk-reclaim [report|quick]" >&2
	exit 2
	;;
esac
