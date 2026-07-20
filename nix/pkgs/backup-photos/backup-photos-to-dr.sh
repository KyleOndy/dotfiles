# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/backup-photos/default.nix).
#
# Laptop-side working-set backup. tiger owns the routine archive/_projects
# -> S3 fan-out now (see nix/pkgs/photos-fanout, run on tiger via a systemd
# timer); this script's job is just the invariant "the working set is never
# single-copy," independent of whether tiger is reachable:
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

readonly PHOTOS_DIR="${HELIOS_LIBRARY_PATH:-$HOME/photos}"
readonly TIGER_HOST="tiger"
readonly TIGER_DEST="/mnt/photos/personal/photos"
readonly AWS_PROFILE="ondy-org"
readonly TF_DIR="${DOTFILES:-$HOME/src/dotfiles/main}/tf"

# Items mirrored to tiger (or a local destination). "archive" is included
# too, guarded by the existing-directory check below, purely for hosts that
# still keep a local kept-tier mirror during the dino->trex transition;
# trex is not expected to have one, since promotion goes straight to
# tiger's archive/ via photos-promote.
readonly SYNC_ITEMS=(
	"archive"
	"_provisional"
	"_projects"
)

sync_to_tiger() {
	echo "Syncing $PHOTOS_DIR to $TIGER_HOST:$TIGER_DEST..."
	if [ -f "$PHOTOS_DIR/helios.db" ]; then
		rsync -a "$PHOTOS_DIR/helios.db" "$TIGER_HOST:$TIGER_DEST/helios.db"
	fi
	for item in "${SYNC_ITEMS[@]}"; do
		src="$PHOTOS_DIR/$item/"
		if [ -d "$src" ]; then
			rsync -a --delete "$src" "$TIGER_HOST:$TIGER_DEST/$item/"
		else
			echo "Warning: $src does not exist, skipping..." >&2
		fi
	done
}

sync_to_local() {
	echo "Syncing $PHOTOS_DIR to $dest_path..."
	mkdir -p "$dest_path"
	if [ -f "$PHOTOS_DIR/helios.db" ]; then
		rsync -a "$PHOTOS_DIR/helios.db" "$dest_path/helios.db"
	fi
	for item in "${SYNC_ITEMS[@]}"; do
		src="$PHOTOS_DIR/$item/"
		if [ -d "$src" ]; then
			# --no-links: many local destinations (e.g. an exFAT travel SSD)
			# can't store symlinks. The only symlinks in the working set are
			# transcoded/{180-rule,not-180-rule}/ categorization pointers back
			# to real files already covered by this same sync, so skipping
			# them loses no data.
			rsync -a --no-links --info=nonreg0 --delete "$src" "$dest_path/$item/"
		else
			echo "Warning: $src does not exist, skipping..." >&2
		fi
	done
}

sync_to_s3() {
	echo "Getting bucket name from terraform..."
	local bucket_name
	bucket_name=$(terraform -chdir="$TF_DIR" output -raw photos_backup_bucket_name)
	if [ -z "$bucket_name" ]; then
		echo "Error: could not get bucket name from terraform output" >&2
		echo "Make sure you've run 'terraform apply' in $TF_DIR first" >&2
		exit 1
	fi

	echo "Opportunistic push to s3://$bucket_name (working set only, RAF excluded)..."
	export AWS_PROFILE
	# Only the working set: archive/ is tiger's job to push (see
	# nix/pkgs/photos-fanout), and pushing it from the laptop too would
	# mean re-uploading the whole archive on every trip.
	for item in "_provisional" "_projects"; do
		src="$PHOTOS_DIR/$item/"
		if [ ! -d "$src" ]; then
			echo "Warning: $src does not exist, skipping..." >&2
			continue
		fi
		storage_class="STANDARD"
		if [ "$item" = "_projects" ]; then
			storage_class="STANDARD_IA"
		fi
		aws s3 sync "$src" "s3://$bucket_name/$item/" \
			--delete --exclude "*.RAF" --exclude "*.raf" \
			--storage-class "$storage_class"
	done
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

echo "Sync complete!"
