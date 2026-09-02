# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/backup-resolve-projects/default.nix).
#
# One command that makes every in-flight video project non-single-copy.
#
#   backup-resolve-projects        mirror to tiger (default, at home)
#   backup-resolve-projects --s3   push offsite to the video scratch bucket
#
# Independent, not exclusive. tiger is the copy you actually restore from,
# and pika replicates it. S3 answers "the house is gone" and nothing else,
# which is why it is a separate bucket from the photo archive with its own
# delete-capable credential (tf/video-scratch.tf).
#
# Two trees, because either alone restores to nothing useful. ~/resolve holds
# the footage, the shot lists and the stringouts. The project library holds
# the timelines, grades and bin structure that reference them, and Resolve
# keeps it under Application Support rather than in the project folder, so
# backing up the project folder alone loses every edit decision ever made.
# Nothing about the on-disk layout hints at that coupling, which is the whole
# reason this is one command instead of two invocations someone has to
# remember to pair.
#
# Deletes propagate in both modes. Clean up a finished project locally and
# the next run removes it from tiger and writes a delete marker in S3. On
# tiger it ages out on the snapshot retention in tiger/configuration.nix; in
# S3 on the noncurrent window in tf/video-scratch.tf.

readonly RESOLVE_DIR="$HOME/resolve"
readonly LIBRARY_DIR="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Resolve Project Library"
readonly TIGER_HOST="tiger"
readonly TIGER_DEST="/mnt/projects"
readonly AWS_PROFILE="ondy-org"
readonly TF_DIR="${DOTFILES:-$HOME/src/dotfiles/main}/tf"

# The camera negative, split from the rest of a project because the two
# halves want different storage classes: it is written once when a card is
# dumped and never touched again, while everything beside it is rewritten
# every session. See tf/video-scratch.tf.
readonly FOOTAGE_DIR="01_Footage"

# Finder leaves droppings in any tree it browses. rsync matches these against
# each path component; aws s3 matches the whole key, hence the second list.
readonly LITTER_EXCLUDES=(
	--exclude ".DS_Store"
	--exclude "._*"
	--exclude ".Spotlight-V100"
	--exclude ".fseventsd"
	--exclude ".TemporaryItems"
	--exclude ".Trashes"
)
readonly S3_LITTER_EXCLUDES=(
	--exclude "*.DS_Store"
	--exclude "._*"
	--exclude "*/._*"
)

bucket_name=""

# --delete against a source that is missing or empty is not a backup, it is a
# one-command wipe of the copy that exists to survive exactly that mistake.
# tiger's snapshots and S3's noncurrent window would both still hold the
# data, but needing them because of this script would be an own goal.
require_populated() {
	if [ ! -d "$1" ]; then
		echo "No directory at $1" >&2
		echo "Refusing to mirror a missing source: --delete would empty the copy." >&2
		exit 1
	fi
	if [ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
		echo "$1 is empty" >&2
		echo "Refusing to mirror an empty source: --delete would empty the copy." >&2
		exit 1
	fi
}

# --info: progress2 is the only thing that distinguishes a large sync in
# flight from a hung ssh connection, and del names what a cleanup is
# propagating, which is the one destructive thing this script does.
mirror() {
	rsync -a --delete --info=progress2,del "${LITTER_EXCLUDES[@]}" "$1/" "$TIGER_HOST:$2/"
}

# aws s3 sync compares size and mtime off the LIST response, so a re-run is a
# directory walk rather than a re-upload, whatever storage class the objects
# sit in. Deep Archive objects never have to be restored to be compared.
#
# No bandwidth cap. awscli exposes max_bandwidth only as a config file key,
# never a flag, and setting it in ~/.aws/config would throttle every other
# use of this profile. The first footage push is roughly 31 hours against a
# 24.6 Mbps uplink, so run it when nobody needs the line. To cap it anyway:
#
#   [profile ondy-org]
#   s3 =
#     max_bandwidth = 2MB/s
push_s3() {
	local src="$1" dest="$2" class="$3"
	shift 3
	echo "  $src -> s3://$bucket_name/$dest/ ($class)"
	aws s3 sync "$src/" "s3://$bucket_name/$dest/" \
		--delete --storage-class "$class" \
		"${S3_LITTER_EXCLUDES[@]}" "$@"
}

sync_to_tiger() {
	echo "Syncing $RESOLVE_DIR to $TIGER_HOST:$TIGER_DEST/resolve/"
	mirror "$RESOLVE_DIR" "$TIGER_DEST/resolve"
	if [ "$library_syncable" -eq 1 ]; then
		echo "Syncing the Resolve project library to $TIGER_HOST:$TIGER_DEST/resolve-project-library/"
		mirror "$LIBRARY_DIR" "$TIGER_DEST/resolve-project-library"
	fi
}

each_project() {
	local project
	for project in "$RESOLVE_DIR"/*/; do
		[ -d "$project" ] || continue
		"$1" "${project%/}" "$(basename "$project")"
	done
}

sync_to_s3() {
	echo "Getting bucket name from terraform..."
	bucket_name=$(terraform -chdir="$TF_DIR" output -raw video_scratch_bucket_name)
	if [ -z "$bucket_name" ]; then
		echo "Error: could not get bucket name from terraform output" >&2
		echo "Make sure you've run 'terraform apply' in $TF_DIR first" >&2
		exit 1
	fi
	export AWS_PROFILE

	# Small and irreplaceable first, bulk last. The footage pass can run
	# for more than a day on a first seed, and a Ctrl-C, a dropped link or
	# a closed laptop lid during it must not be what stops the edit from
	# reaching the bucket. Ordering is the whole protection here; there is
	# no resume.
	echo "Edit decisions:"
	each_project push_project
	if [ "$library_syncable" -eq 1 ]; then
		push_s3 "$LIBRARY_DIR" "project/_resolve-library" STANDARD_IA
	fi

	echo "Camera negative:"
	each_project push_footage
}

# Everything that is not the negative: shot lists, stringouts, graphics,
# exports. Tens of MB, rewritten constantly, and the half you would actually
# want back in a hurry.
#
# Two patterns for one directory. awscli documents its filters as matching
# "the full path" of a file, but what that means for a local source has moved
# between versions, so the relative form alone is not safe to rely on.
# Getting this wrong is expensive rather than cosmetic: the footage silently
# lands here too, at Standard-IA and a second time.
#   https://docs.aws.amazon.com/cli/latest/reference/s3/#use-of-exclude-and-include-filters
push_project() {
	push_s3 "$1" "project/$2" STANDARD_IA \
		--exclude "$FOOTAGE_DIR/*" --exclude "*/$FOOTAGE_DIR/*"
}

push_footage() {
	[ -d "$1/$FOOTAGE_DIR" ] || return 0
	push_s3 "$1/$FOOTAGE_DIR" "footage/$2" DEEP_ARCHIVE
}

mode="tiger"
case "${1:-}" in
"--s3")
	mode="s3"
	;;
"") ;;
*)
	echo "Usage: backup-resolve-projects [--s3]" >&2
	exit 1
	;;
esac
readonly mode

# The project library is a live SQLite database. A copy taken while Resolve
# holds it open is torn, and a torn database restores as a corrupt project,
# which is worse than no copy because it still looks like a backup. Checked
# up front rather than at the point of use: the footage sync below can run
# for hours, and finding out afterwards that the half that matters was
# skipped is a bad way to spend them.
#
# pgrep comes from macOS at /usr/bin/pgrep. This script only ever installs on
# trex (darwin), and nixpkgs procps is Linux-only, so there is nothing to add
# to runtimeInputs for it.
library_syncable=1
if pgrep -x Resolve >/dev/null 2>&1; then
	library_syncable=0
	echo "DaVinci Resolve is running: the project library will be SKIPPED." >&2
	echo "Syncing $RESOLVE_DIR anyway, since plain files copy safely either way." >&2
	echo >&2
fi

require_populated "$RESOLVE_DIR"
if [ "$library_syncable" -eq 1 ]; then
	require_populated "$LIBRARY_DIR"
fi

case "$mode" in
"tiger") sync_to_tiger ;;
"s3") sync_to_s3 ;;
esac

if [ "$library_syncable" -eq 0 ]; then
	echo >&2
	echo "Footage is backed up. The project library is NOT: quit Resolve and run this again." >&2
	exit 1
fi
