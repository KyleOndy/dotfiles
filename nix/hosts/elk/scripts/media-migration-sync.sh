#!/usr/bin/env bash
set -euo pipefail

WOLF="/mnt/wolf-media"
LOCAL="/mnt/storage/media-local"
CATEGORIES=("movies" "tv" "music" "books" "yt")

if ! mountpoint -q "$WOLF"; then
	echo "Error: wolf NFS not mounted at $WOLF"
	exit 1
fi

echo "Syncing all media from wolf → elk-local"
echo "  From: $WOLF"
echo "  To:   $LOCAL"
echo ""

echo "Repairing directory permissions..."
sudo find "$LOCAL" -type d \( ! -group media -o ! -perm -g+w \) \
	-exec chgrp media {} + -exec chmod 2775 {} + 2>/dev/null || true

for cat in "${CATEGORIES[@]}"; do
	rsync -avP --size-only --no-times --append-verify --chmod=D2775,F664 --no-owner --no-group --exclude='*.trickplay' "$WOLF/$cat/" "$LOCAL/$cat/"
done

echo ""
echo "Sync complete."
