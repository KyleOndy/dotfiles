# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/s3-archive-push/default.nix).
#
# Runs on pika, pushing one replicated dataset to the offsite archive bucket.
# tiger holds no AWS credential: it faces the internet, and the offsite copy
# is what insures against it.
#
#   s3-archive-push tank/photos photos
#   s3-archive-push tank/backups backups
#
# DEEP_ARCHIVE is set on the PUT rather than reached by a lifecycle
# transition. Transitions skip objects under 128 KB by default, which would
# strand every sidecar in Standard at 23x the price with nothing reporting it
# (tf/archive-backup.tf).
#
# No --delete. This credential has no delete verb at all; orphan removal is
# s3-archive-prune's job, with a different credential and a sanity threshold.

: "${ARCHIVE_BUCKET:?ARCHIVE_BUCKET must be set}"

readonly DATASET="${1:?usage: s3-archive-push <dataset> <prefix>}"
readonly PREFIX="${2:?usage: s3-archive-push <dataset> <prefix>}"
readonly TEXTFILE_DIR="/var/lib/prometheus-node-exporter-text-files"
readonly OUTFILE="$TEXTFILE_DIR/s3_archive_$PREFIX.prom"

# A received dataset does not mount itself, and `aws s3 sync` against an empty
# mountpoint is indistinguishable from a healthy run that had nothing to do.
# Refusing here is what turns that into a failed unit and a firing alert.
mounted=$(zfs get -H -o value mounted "$DATASET")
if [ "$mounted" != "yes" ]; then
	echo "$DATASET is not mounted, refusing to sync an empty tree" >&2
	exit 1
fi

SOURCE=$(zfs get -H -o value mountpoint "$DATASET")
readonly SOURCE
if [ ! -d "$SOURCE" ]; then
	echo "$DATASET reports mountpoint $SOURCE, which is not a directory" >&2
	exit 1
fi

started=$(date +%s)
echo "syncing $SOURCE -> s3://$ARCHIVE_BUCKET/$PREFIX/ (Deep Archive)"
aws s3 sync "$SOURCE/" "s3://$ARCHIVE_BUCKET/$PREFIX/" \
	--storage-class DEEP_ARCHIVE \
	--only-show-errors
finished=$(date +%s)

objects=$(find "$SOURCE" -type f | wc -l)
bytes=$(du -sb "$SOURCE" | cut -f1)

# What the source holds, not what the bucket holds. s3-archive-reconcile owns
# the comparison; publishing both sides from one job would let a single bug
# claim agreement that was never checked.
{
	printf '# HELP s3_archive_push_last_success_timestamp_seconds Unix time this prefix last synced cleanly\n'
	printf '# TYPE s3_archive_push_last_success_timestamp_seconds gauge\n'
	printf 's3_archive_push_last_success_timestamp_seconds{prefix="%s"} %s\n' "$PREFIX" "$finished"
	printf '# HELP s3_archive_push_duration_seconds Wall time of the last successful sync\n'
	printf '# TYPE s3_archive_push_duration_seconds gauge\n'
	printf 's3_archive_push_duration_seconds{prefix="%s"} %s\n' "$PREFIX" "$((finished - started))"
	printf '# HELP s3_archive_push_source_objects Files under the source dataset\n'
	printf '# TYPE s3_archive_push_source_objects gauge\n'
	printf 's3_archive_push_source_objects{prefix="%s"} %s\n' "$PREFIX" "$objects"
	printf '# HELP s3_archive_push_source_bytes Bytes under the source dataset\n'
	printf '# TYPE s3_archive_push_source_bytes gauge\n'
	printf 's3_archive_push_source_bytes{prefix="%s"} %s\n' "$PREFIX" "$bytes"
} >"$OUTFILE.tmp"
mv "$OUTFILE.tmp" "$OUTFILE"

echo "done in $((finished - started))s: $objects objects, $bytes bytes at source"
