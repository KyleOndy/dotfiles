#!/usr/bin/env bash
set -euo pipefail

WOLF_MEDIA="wolf:/mnt/storage/media"
LOCAL="/mnt/storage/media"
CATEGORIES=("tv" "movies")

if ! sudo ssh -o ConnectTimeout=5 wolf true 2>/dev/null; then
	echo "Error: cannot reach wolf via SSH"
	exit 1
fi

echo "Syncing all media from wolf → elk-local"
echo "  From: $WOLF_MEDIA"
echo "  To:   $LOCAL"
echo ""

for cat in "${CATEGORIES[@]}"; do
	sudo rsync -avP --size-only --append-verify --chmod=D2775,F664 --no-owner --no-group --exclude='*.trickplay' "$WOLF_MEDIA/$cat/" "$LOCAL/$cat/"
done

echo ""
echo "Sync complete."
