# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/backup-git-repos/default.nix).
#
# Bundle every repo under ~/src and push the bundles into storage/backups,
# for repos that have no remote of their own.
#
# One bundle per repo rather than a copy of .git. A bundle is a single file,
# so the S3 tier holds one object per repo instead of thousands of loose
# objects and superseded packs, and it is written whole, so a copy can never
# catch git mid-write. --all carries every branch, tag and worktree HEAD.
# It does not carry reflogs, so stashes older than the newest are not kept.
#
# Bundles are staged in STAGING and kept between runs. Packing is not
# deterministic, so a rebuilt bundle with the same refs is a different file;
# keeping the old one when the refs match is what makes rsync, and the S3
# sync behind it, skip unchanged repos.
#
# The destination is overwritten every run. Its history is the ZFS snapshot
# history of storage/backups, so there is no rotation here. Nothing is ever
# deleted on tiger: a repo removed locally keeps its last bundle there.

readonly SRC="${BACKUP_GIT_SRC:-$HOME/src}"
readonly DEST="${1:?usage: backup-git-repos <directory|[user@]host:directory>}"
readonly STAGING="${XDG_CACHE_HOME:-$HOME/.cache}/backup-git-repos"

mkdir -p "$STAGING"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for repo in "$SRC"/*/; do
	[ -e "$repo.git" ] || continue
	name="$(basename "$repo")"
	bundle="$STAGING/$name.bundle"

	if [ -z "$(git -C "$repo" for-each-ref)" ]; then
		echo "$name: no commits, skipped"
		continue
	fi

	git -C "$repo" bundle create --quiet "$tmp/$name.bundle" --all
	# verify reports "is okay" on stderr even with --quiet.
	if ! out="$(git -C "$repo" bundle verify --quiet "$tmp/$name.bundle" 2>&1)"; then
		echo "$out" >&2
		exit 1
	fi
	if [ -e "$bundle" ] &&
		[ "$(git bundle list-heads "$bundle")" = "$(git bundle list-heads "$tmp/$name.bundle")" ]; then
		echo "$name: unchanged"
	else
		mv -f "$tmp/$name.bundle" "$bundle"
		echo "$name: bundled"
	fi

	# A bundle carries git-crypt's ciphertext but not its key, which lives in
	# the git dir. Without it the encrypted paths restore as noise. Every
	# worktree holds the same key, so the first one found is the key.
	common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)"
	keys="$(find "$common" -type d -path '*/git-crypt/keys' -print -quit)"
	if [ -n "$keys" ]; then
		rsync -a --delete "$keys/" "$STAGING/$name.git-crypt-keys/"
	fi
done

rsync -a --mkpath "$STAGING/" "$DEST/"
echo "backup-git-repos: pushed to $DEST"
