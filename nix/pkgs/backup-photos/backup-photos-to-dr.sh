# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/backup-photos/default.nix).

readonly PHOTOS_DIR="${HELIOS_LIBRARY_PATH:-$HOME/photos}"
readonly TIGER_HOST="tiger"
readonly TIGER_DEST="/mnt/photos/personal/photos"
readonly AWS_PROFILE="ondy-org"
readonly TF_DIR="${DOTFILES:-$HOME/src/dotfiles/main}/tf"

# Directories backed up in full to tiger (a fast local restore tier, riding
# on its existing ZFS snapshots) and, minus raws, to S3 Deep Archive (the
# last-ditch disaster recovery tier). RAF files are a local edit cache, not
# something worth paying to keep in the cloud. helios.db is a single file
# rather than a directory, so it is synced separately below.
readonly SYNC_ITEMS=(
	"archive"
	"_provisional"
)

export AWS_PROFILE

echo "Syncing $PHOTOS_DIR to $TIGER_HOST:$TIGER_DEST..."
rsync -a "$PHOTOS_DIR/helios.db" "$TIGER_HOST:$TIGER_DEST/helios.db"
for item in "${SYNC_ITEMS[@]}"; do
	src="$PHOTOS_DIR/$item/"
	if [ -d "$src" ]; then
		rsync -a --delete "$src" "$TIGER_HOST:$TIGER_DEST/$item/"
	else
		echo "Warning: $src does not exist, skipping..." >&2
	fi
done

echo "Getting bucket name from terraform..."
BUCKET_NAME=$(terraform -chdir="$TF_DIR" output -raw photos_backup_bucket_name)
if [ -z "$BUCKET_NAME" ]; then
	echo "Error: could not get bucket name from terraform output" >&2
	echo "Make sure you've run 'terraform apply' in $TF_DIR first" >&2
	exit 1
fi

echo "Syncing to bucket: $BUCKET_NAME"
aws s3 cp "$PHOTOS_DIR/helios.db" "s3://$BUCKET_NAME/helios.db"
for item in "${SYNC_ITEMS[@]}"; do
	src="$PHOTOS_DIR/$item/"
	if [ -d "$src" ]; then
		aws s3 sync "$src" "s3://$BUCKET_NAME/$item/" --delete --exclude "*.RAF" --exclude "*.raf"
	else
		echo "Warning: $src does not exist, skipping..." >&2
	fi
done

echo "Sync complete!"
