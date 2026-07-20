# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/photos-fanout/default.nix).
#
# Runs on tiger only (systemd.services.photos-fanout in
# nix/hosts/tiger/configuration.nix), fanning the authoritative archive out
# to cold storage. This is the routine, at-home half of the backup story;
# the laptop's own backup-photos handles the working set
# (_provisional/_projects) and the vacation case independently, so this
# service being down or tiger being unreachable never blocks that.
#
#   archive/    -> S3 Deep Archive (RAF excluded; helios's README calls raws
#                  "a local edit cache, not archival")
#              -> external HDD, best effort, only if mounted
#   _projects/  -> S3 Standard-IA (churny WIP; Deep Archive's 180-day
#                  minimum-storage charge and re-upload-on-modtime-change
#                  make it a bad fit for actively-edited projects)
#
# PHOTOS_BACKUP_BUCKET must be set (see nix/hosts/tiger/configuration.nix);
# it is a plain bucket name, not looked up from terraform state, since
# tiger does not carry a dotfiles checkout with terraform state.

: "${PHOTOS_BACKUP_BUCKET:?PHOTOS_BACKUP_BUCKET must be set}"
readonly PHOTOS_DIR="/mnt/photos/personal/photos"
readonly AWS_PROFILE="ondy-org"
readonly EXTERNAL_HDD_MOUNT="${PHOTOS_EXTERNAL_HDD_MOUNT:-/mnt/photos-external}"

export AWS_PROFILE

echo "Fanning out $PHOTOS_DIR/archive to s3://$PHOTOS_BACKUP_BUCKET (Deep Archive)..."
aws s3 sync "$PHOTOS_DIR/archive/" "s3://$PHOTOS_BACKUP_BUCKET/archive/" \
	--delete --exclude "*.RAF" --exclude "*.raf"

if [ -d "$PHOTOS_DIR/_projects" ]; then
	echo "Fanning out $PHOTOS_DIR/_projects to s3://$PHOTOS_BACKUP_BUCKET (Standard-IA)..."
	aws s3 sync "$PHOTOS_DIR/_projects/" "s3://$PHOTOS_BACKUP_BUCKET/_projects/" \
		--delete --storage-class STANDARD_IA
else
	echo "No _projects directory yet, skipping S3 push for it."
fi

if [ -f "$PHOTOS_DIR/helios.db" ]; then
	aws s3 cp "$PHOTOS_DIR/helios.db" "s3://$PHOTOS_BACKUP_BUCKET/helios.db"
fi

if mountpoint -q "$EXTERNAL_HDD_MOUNT" 2>/dev/null; then
	echo "External HDD mounted at $EXTERNAL_HDD_MOUNT, mirroring archive (+ best-effort RAF)..."
	rsync -a --delete "$PHOTOS_DIR/archive/" "$EXTERNAL_HDD_MOUNT/archive/"
else
	echo "External HDD not mounted at $EXTERNAL_HDD_MOUNT, skipping that copy."
fi

echo "Fan-out complete!"
