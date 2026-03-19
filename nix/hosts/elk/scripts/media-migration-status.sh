#!/usr/bin/env bash
set -euo pipefail

WOLF="/mnt/wolf-media"
LOCAL="/mnt/storage/media-local"
CATEGORIES=("movies" "tv" "music" "books" "yt")

# Check mounts
if ! mountpoint -q "$WOLF" 2>/dev/null; then
	echo "WARNING: Wolf NFS not mounted at $WOLF — can only show local files"
	echo ""
fi

for cat in "${CATEGORIES[@]}"; do
	wolf_dir="$WOLF/$cat"
	local_dir="$LOCAL/$cat"

	echo "=== $cat ==="

	# Get sorted directory listings (top-level entries only)
	wolf_list=$(find "$wolf_dir" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sort)
	local_list=$(find "$local_dir" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sort)

	wolf_only=$(comm -23 <(echo "$wolf_list") <(echo "$local_list") | grep -c . || true)
	local_only=$(comm -13 <(echo "$wolf_list") <(echo "$local_list") | grep -c . || true)
	both=$(comm -12 <(echo "$wolf_list") <(echo "$local_list") | grep -c . || true)

	echo "  wolf-only: $wolf_only    elk-only: $local_only    both: $both"

	# Detailed listing with --detail flag
	if [[ ${1:-} == "--detail" || ${1:-} == "-d" ]]; then
		if [[ $wolf_only -gt 0 ]]; then
			echo "  --- wolf-only (need to migrate) ---"
			comm -23 <(echo "$wolf_list") <(echo "$local_list") | sed 's/^/    /'
		fi
		if [[ $both -gt 0 ]]; then
			echo "  --- on both (can delete from wolf) ---"
			comm -12 <(echo "$wolf_list") <(echo "$local_list") | sed 's/^/    /'
		fi
	fi
	echo ""
done

# Summary
echo "=== Summary ==="
total_wolf=0
total_local=0
total_both=0
for cat in "${CATEGORIES[@]}"; do
	wolf_list=$(find "$WOLF/$cat" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sort)
	local_list=$(find "$LOCAL/$cat" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | sort)
	total_wolf=$((total_wolf + $(comm -23 <(echo "$wolf_list") <(echo "$local_list") | grep -c . || true)))
	total_local=$((total_local + $(comm -13 <(echo "$wolf_list") <(echo "$local_list") | grep -c . || true)))
	total_both=$((total_both + $(comm -12 <(echo "$wolf_list") <(echo "$local_list") | grep -c . || true)))
done
echo "  Total wolf-only: $total_wolf (need migrating)"
echo "  Total elk-only:  $total_local"
echo "  Total on both:   $total_both (can clean from wolf)"
