# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/backup-photos/default.nix).
#
# Laptop-side working-set backup. tiger owns the routine archive -> S3 fan-out
# now (see nix/pkgs/photos-fanout, run on tiger via a systemd timer); this
# script's job is just the invariant "the working set is never single-copy,"
# independent of whether tiger is reachable:
#
#   backup-photos              mirror to tiger over ssh (default, at home)
#   backup-photos --to PATH    mirror to a local path, e.g. a mounted
#                               external SSD kept separate from the laptop
#                               while traveling
#   backup-photos --s3         opportunistic direct-to-S3 push of the
#                               working set, for trips where even the SSD
#                               copy isn't enough (irreplaceable shoots,
#                               want an offsite copy before getting home)
#
# These are independent, not exclusive: run more than one on a given trip
# if you want belt and suspenders.
#
# Authority is per shoot, not per tree. The laptop holds a handful of shoots
# out of tiger's 1460, so --delete against _provisional/ as a whole would
# erase every shoot not currently being worked on. Scoped to a shoot the
# laptop does hold, --delete is what propagates a winnow cull. The corollary
# is that deleting a whole shoot directory locally propagates nowhere, because
# an absent directory is never enumerated; pruning a remote copy after
# photos-promote is a deliberate act against tiger.

readonly PHOTOS_DIR="${HELIOS_LIBRARY_PATH:-$HOME/photos}"
# helios keeps its dedup database in XDG state, not in the library (see
# nix/pkgs/helios/README.md). Copying it alongside the photos is what makes
# a restored library still know what it has already seen.
readonly HELIOS_DB="${HELIOS_DB_PATH:-${XDG_STATE_HOME:-$HOME/.local/state}/helios/helios.db}"
readonly TIGER_HOST="tiger"
readonly TIGER_DEST="/mnt/photos/personal/photos"
readonly AWS_PROFILE="ondy-org"
readonly TF_DIR="${DOTFILES:-$HOME/src/dotfiles/main}/tf"

# "<tree>:<depth>", where depth is how far below the tree a shoot directory
# sits. Declared rather than discovered: selecting units by "directory that
# contains files" would promote a stray file at _provisional/<year>/ into a
# sync unit, putting --delete scope over an entire year. helios lands undated
# files in _provisional/0000/0000_00_00 to keep this depth uniform.
#
# "archive" is here for hosts that keep a local kept-tier mirror, guarded by
# the existing-directory check below; trex is not expected to have one, since
# promotion goes straight to tiger's archive/ via photos-promote.
readonly SYNC_ITEMS=(
	"archive:1"
	"_provisional:2"
)

# trex writes to this library over SMB, and Finder leaves droppings wherever
# it browses.
readonly LITTER_EXCLUDES=(
	--exclude ".DS_Store"
	--exclude "._*"
	--exclude ".Spotlight-V100"
	--exclude ".fseventsd"
	--exclude ".TemporaryItems"
	--exclude ".Trashes"
)

# Shoot directories the laptop currently holds, one per line.
shoot_dirs() {
	find "$1" -mindepth "$2" -maxdepth "$2" -type d
}

# Anything above shoot depth is silently unsynced, so say so rather than
# leaving it to be discovered by its absence years later. Dotfiles are the
# litter excluded above, not data.
warn_strays() {
	local strays
	strays=$(find "$1" -mindepth 1 -maxdepth "$2" -not -type d -not -name ".*" | wc -l)
	if [ "$strays" -gt 0 ]; then
		echo "Warning: $strays file(s) above shoot depth in $1 will not be synced" >&2
	fi
}

# Run a command for every shoot in each named tree that exists locally. The
# callback receives the absolute shoot directory and its path relative to
# $PHOTOS_DIR. Every tree is enumerated before the first shoot is synced so
# the per-shoot line can carry a total; streaming would only ever know where
# the run is, not how far it has left to go.
for_each_shoot() {
	local callback="$1"
	shift
	local spec item depth src dir rel i=0
	local shoots=()
	for spec in "$@"; do
		item="${spec%:*}"
		depth="${spec#*:}"
		src="$PHOTOS_DIR/$item"
		if [ ! -d "$src" ]; then
			echo "Warning: $src does not exist, skipping..." >&2
			continue
		fi
		warn_strays "$src" "$depth"
		while IFS= read -r dir; do
			shoots+=("$dir")
		done < <(shoot_dirs "$src" "$depth")
	done
	for dir in "${shoots[@]}"; do
		rel="${dir#"$PHOTOS_DIR"/}"
		i=$((i + 1))
		echo "[$i/${#shoots[@]}] $rel"
		"$callback" "$dir" "$rel"
	done
}

copy_helios_db() {
	if [ -f "$HELIOS_DB" ]; then
		rsync -a "$HELIOS_DB" "$1"
	else
		echo "Warning: no helios database at $HELIOS_DB, not backing it up" >&2
	fi
}

# --mkpath: a shoot sits below its tree (_provisional/<year>/<date>), and rsync
# only ever creates the last component of a destination path on its own.
#
# --info: progress2 is the only thing distinguishing a large shoot in flight
# from a hung ssh connection, and del names the files a winnow cull is
# propagating, which is the one destructive thing this script does.
shoot_to_tiger() {
	rsync -a --delete --mkpath --info=progress2,del "${LITTER_EXCLUDES[@]}" \
		"$1/" "$TIGER_HOST:$TIGER_DEST/$2/"
}

sync_to_tiger() {
	echo "Syncing $PHOTOS_DIR to $TIGER_HOST:$TIGER_DEST..."
	copy_helios_db "$TIGER_HOST:$TIGER_DEST/helios.db"
	for_each_shoot shoot_to_tiger "${SYNC_ITEMS[@]}"
}

shoot_to_local() {
	# --no-links: many local destinations (e.g. an exFAT travel SSD) can't
	# store symlinks. The only symlinks in the working set are
	# transcoded/{180-rule,not-180-rule}/ categorization pointers back to real
	# files already covered by this same sync, so skipping them loses no data.
	rsync -a --no-links --info=nonreg0,progress2,del --delete --mkpath "${LITTER_EXCLUDES[@]}" \
		"$1/" "$dest_path/$2/"
}

sync_to_local() {
	echo "Syncing $PHOTOS_DIR to $dest_path..."
	mkdir -p "$dest_path"
	copy_helios_db "$dest_path/helios.db"
	for_each_shoot shoot_to_local "${SYNC_ITEMS[@]}"
}

shoot_to_s3() {
	aws s3 sync "$1/" "s3://$bucket_name/$2/" \
		--delete --exclude "*.RAF" --exclude "*.raf" \
		--exclude ".DS_Store" --exclude "._*" \
		--storage-class STANDARD
}

sync_to_s3() {
	echo "Getting bucket name from terraform..."
	bucket_name=$(terraform -chdir="$TF_DIR" output -raw photos_backup_bucket_name)
	if [ -z "$bucket_name" ]; then
		echo "Error: could not get bucket name from terraform output" >&2
		echo "Make sure you've run 'terraform apply' in $TF_DIR first" >&2
		exit 1
	fi

	echo "Opportunistic push to s3://$bucket_name (working set only, RAF excluded)..."
	export AWS_PROFILE
	# _provisional only, not the whole of SYNC_ITEMS: archive/ is tiger's job
	# to push (see nix/pkgs/photos-fanout), and pushing it from the laptop too
	# would mean re-uploading the whole archive on every trip. Uploads land in
	# STANDARD; the lifecycle rules in tf/photos-backup.tf transition from
	# there.
	for_each_shoot shoot_to_s3 "_provisional:2"
}

mode="tiger"
dest_path=""
case "${1:-}" in
"--to")
	mode="local"
	dest_path="${2:?--to requires a destination path}"
	;;
"--s3")
	mode="s3"
	;;
"") ;;
*)
	echo "Usage: backup-photos [--to PATH | --s3]" >&2
	exit 1
	;;
esac

case "$mode" in
tiger) sync_to_tiger ;;
local) sync_to_local ;;
s3) sync_to_s3 ;;
esac

echo "Sync complete in ${SECONDS}s"
