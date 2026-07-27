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
#   archive/    -> S3 Deep Archive
#   _projects/  -> S3 Standard-IA (churny WIP; Deep Archive's 180-day
#                  minimum-storage charge and re-upload-on-modtime-change
#                  make it a bad fit for actively-edited projects)
#
# No leg passes --delete, and the IAM policy no longer carries a delete verb
# to back one up (tf/photos-backup.tf). An rm here must not be able to reach
# the offsite copy a day later. Pruning the bucket is a deliberate, rare,
# manual job; at Deep Archive rates, hoarding is cheaper than the risk.
#
# The external HDD leg is gone. It was best effort with no alerting, which
# is indistinguishable from not trying: every run for months ended with
# "External HDD not mounted ... skipping that copy" and exit code 0. pika
# does that job properly, over ZFS send, with staleness alerts.
#
# RAF files are included. They were excluded on the reasoning in
# helios/README.md:65-67 that raws are a local edit cache rather than
# archival. That is true right up until the JPEG is the only thing left. The
# exclusion saved about $0.02/month.
#
# PHOTOS_BACKUP_BUCKET must be set (see nix/hosts/tiger/configuration.nix);
# it is a plain bucket name, not looked up from terraform state, since
# tiger does not carry a dotfiles checkout with terraform state.

: "${PHOTOS_BACKUP_BUCKET:?PHOTOS_BACKUP_BUCKET must be set}"
readonly PHOTOS_DIR="/mnt/photos/personal/photos"
readonly AWS_PROFILE="ondy-org"

export AWS_PROFILE

echo "Fanning out $PHOTOS_DIR/archive to s3://$PHOTOS_BACKUP_BUCKET (Deep Archive)..."
aws s3 sync "$PHOTOS_DIR/archive/" "s3://$PHOTOS_BACKUP_BUCKET/archive/"

if [ -d "$PHOTOS_DIR/_projects" ]; then
	echo "Fanning out $PHOTOS_DIR/_projects to s3://$PHOTOS_BACKUP_BUCKET (Standard-IA)..."
	aws s3 sync "$PHOTOS_DIR/_projects/" "s3://$PHOTOS_BACKUP_BUCKET/_projects/" \
		--storage-class STANDARD_IA
else
	echo "No _projects directory yet, skipping S3 push for it."
fi

# backup-photos on the laptop is what puts helios.db here; helios itself
# keeps it in XDG state on trex and never writes into the library.
if [ -f "$PHOTOS_DIR/helios.db" ]; then
	aws s3 cp "$PHOTOS_DIR/helios.db" "s3://$PHOTOS_BACKUP_BUCKET/helios.db"
else
	echo "Warning: no helios.db at $PHOTOS_DIR, has backup-photos run?" >&2
fi

echo "Fan-out complete!"
