# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/s3-archive-reconcile/default.nix).
#
# Compares one replicated dataset against its prefix in the offsite archive
# bucket. With --prune it removes bucket objects the source does not have.
#
#   s3-archive-reconcile tank/photos photos            # report only
#   s3-archive-reconcile --prune tank/photos photos    # report and delete
#
# One script rather than two so the set difference that reports and the set
# difference that deletes cannot drift apart. The two callers differ only in
# the --prune flag. Both carry the archive-prune credential
# (reconcileUnit in pika/configuration.nix), so nothing at the API stops a
# report-only unit from deleting if --prune reaches it.
#
# Deletion here writes delete markers. No principal in the fleet holds
# s3:DeleteObjectVersion, so nothing this script does destroys a byte; the
# 180-day lifecycle rule in tf/archive-backup.tf is the only thing that ever
# reclaims space.
#
#   orphans  present in S3, absent at the source. Your deletions, untidied.
#   missing  present at the source, absent from S3. The actual emergency.

: "${ARCHIVE_BUCKET:?ARCHIVE_BUCKET must be set}"

readonly PRUNE_THRESHOLD_PCT=5

prune=no
if [ "${1:-}" = "--prune" ]; then
	prune=yes
	shift
fi
readonly prune

readonly DATASET="${1:?usage: s3-archive-reconcile [--prune] <dataset> <prefix>}"
readonly PREFIX="${2:?usage: s3-archive-reconcile [--prune] <dataset> <prefix>}"
readonly TEXTFILE_DIR="/var/lib/prometheus-node-exporter-text-files"
readonly OUTFILE="$TEXTFILE_DIR/s3_reconcile_$PREFIX.prom"

# The bucket only compares to the source between pushes. A push carrying a
# bulk import runs for a day or more against the 2MB/s cap, and every file it
# has not reached yet reads as missing: the run of 2026-08-25 landed mid-sync
# and scored 1515 missing against 186 orphans it then pruned. Scheduling
# cannot avoid this on its own, because a Persistent timer whose stamp
# predates a changed OnCalendar fires at the next activation whatever the
# clock says, which is how that run started.
#
# Skipping leaves s3_reconcile_last_run_timestamp_seconds untouched, so a
# skip reads as staleness rather than as a clean comparison.
# S3ReconcileStale allows 14 days against a weekly timer.
if systemctl is-active --quiet "s3-archive-push-$PREFIX.service"; then
	echo "s3-archive-push-$PREFIX is mid-sync, skipping: every file it has not reached yet would read as missing" >&2
	exit 0
fi

mounted=$(zfs get -H -o value mounted "$DATASET")
if [ "$mounted" != "yes" ]; then
	echo "$DATASET is not mounted; every object would look like an orphan" >&2
	exit 1
fi

SOURCE=$(zfs get -H -o value mountpoint "$DATASET")
readonly SOURCE

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

(cd "$SOURCE" && find . -type f -printf '%P\n') | sort >"$work/local"

# list-objects-v2 paginates on its own. --output json through jq rather than
# --output text because a key may contain a tab.
aws s3api list-objects-v2 \
	--bucket "$ARCHIVE_BUCKET" \
	--prefix "$PREFIX/" \
	--query 'Contents[].Key' \
	--output json |
	jq -r '.[]? // empty' |
	sed "s|^$PREFIX/||" |
	sort >"$work/s3"

comm -13 "$work/local" "$work/s3" >"$work/orphans"
comm -23 "$work/local" "$work/s3" >"$work/missing"

local_count=$(wc -l <"$work/local")
s3_count=$(wc -l <"$work/s3")
orphan_count=$(wc -l <"$work/orphans")
missing_count=$(wc -l <"$work/missing")

echo "$PREFIX: source $local_count, bucket $s3_count, orphans $orphan_count, missing $missing_count"

deleted=0
blocked=0
if [ "$prune" = yes ] && [ "$orphan_count" -gt 0 ]; then
	# A large orphan set almost never means you deleted a lot. It means the
	# source listing is wrong, and acting on it would propagate that to the
	# one copy that survives the house.
	allowed=$((s3_count * PRUNE_THRESHOLD_PCT / 100))
	if [ "$orphan_count" -gt "$allowed" ]; then
		blocked=1
		echo "refusing to prune: $orphan_count orphans exceeds $PRUNE_THRESHOLD_PCT% of $s3_count objects ($allowed)" >&2
	else
		split -l 1000 "$work/orphans" "$work/batch."
		for batch in "$work"/batch.*; do
			jq -Rn --arg p "$PREFIX" \
				'{Objects: [inputs | {Key: ($p + "/" + .)}], Quiet: true}' \
				<"$batch" >"$work/payload.json"
			aws s3api delete-objects \
				--bucket "$ARCHIVE_BUCKET" \
				--delete "file://$work/payload.json" >/dev/null
		done
		deleted=$orphan_count
		echo "wrote $deleted delete markers"
	fi
fi

{
	printf '# HELP s3_reconcile_orphan_objects Objects in the bucket with no counterpart at the source\n'
	printf '# TYPE s3_reconcile_orphan_objects gauge\n'
	printf 's3_reconcile_orphan_objects{prefix="%s"} %s\n' "$PREFIX" "$orphan_count"
	printf '# HELP s3_reconcile_missing_objects Source files absent from the bucket\n'
	printf '# TYPE s3_reconcile_missing_objects gauge\n'
	printf 's3_reconcile_missing_objects{prefix="%s"} %s\n' "$PREFIX" "$missing_count"
	printf '# HELP s3_reconcile_bucket_objects Objects the bucket holds under this prefix\n'
	printf '# TYPE s3_reconcile_bucket_objects gauge\n'
	printf 's3_reconcile_bucket_objects{prefix="%s"} %s\n' "$PREFIX" "$s3_count"
	printf '# HELP s3_reconcile_pruned_objects Delete markers written by the last run\n'
	printf '# TYPE s3_reconcile_pruned_objects gauge\n'
	printf 's3_reconcile_pruned_objects{prefix="%s"} %s\n' "$PREFIX" "$deleted"
	printf '# HELP s3_reconcile_prune_blocked Whether the orphan threshold refused a prune\n'
	printf '# TYPE s3_reconcile_prune_blocked gauge\n'
	printf 's3_reconcile_prune_blocked{prefix="%s"} %s\n' "$PREFIX" "$blocked"
	printf '# HELP s3_reconcile_last_run_timestamp_seconds Unix time of the last completed comparison\n'
	printf '# TYPE s3_reconcile_last_run_timestamp_seconds gauge\n'
	printf 's3_reconcile_last_run_timestamp_seconds{prefix="%s"} %s\n' "$PREFIX" "$(date +%s)"
} >"$OUTFILE.tmp"
mv "$OUTFILE.tmp" "$OUTFILE"

# Non-zero so the unit fails and the refusal is visible as more than a gauge
# nobody graphed.
[ "$blocked" -eq 0 ]
