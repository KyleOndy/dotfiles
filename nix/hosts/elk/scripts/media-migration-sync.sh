#!/usr/bin/env bash
set -euo pipefail

WOLF="/mnt/wolf-media"
LOCAL="/mnt/storage/media-local"

usage() {
	echo "Usage: media-migration-sync <category> <name>"
	echo ""
	echo "Categories: movies, tv, music, books, yt"
	echo ""
	echo "Examples:"
	echo "  media-migration-sync movies 'Some Movie (2024)'"
	echo "  media-migration-sync tv 'Some Show'"
	echo ""
	echo "Use 'media-migration-status --detail' to see what needs migrating."
	exit 1
}

if [[ $# -lt 2 ]]; then
	usage
fi

CATEGORY="$1"
shift
NAME="$*"

# Validate category
case "$CATEGORY" in
movies | tv | music | books | yt) ;;
*)
	echo "Error: unknown category '$CATEGORY'"
	usage
	;;
esac

SRC="$WOLF/$CATEGORY/$NAME"
DST="$LOCAL/$CATEGORY/$NAME"

if [[ ! -e $SRC ]]; then
	echo "Error: '$SRC' does not exist on wolf"
	echo ""
	echo "Available in $CATEGORY on wolf:"
	find "$WOLF/$CATEGORY/" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | head -20
	exit 1
fi

if [[ -e $DST ]]; then
	echo "Warning: '$DST' already exists on elk-local"
	echo "Continuing will sync any differences..."
	echo ""
fi

# Show what we're about to do
SRC_SIZE=$(du -sh "$SRC" 2>/dev/null | cut -f1)
echo "Syncing: $CATEGORY/$NAME ($SRC_SIZE)"
echo "  From: $SRC"
echo "  To:   $DST"
echo ""
read -rp "Proceed? [y/N] " confirm
if [[ $confirm != [yY] ]]; then
	echo "Aborted."
	exit 0
fi

# Ensure parent directory exists
mkdir -p "$(dirname "$DST")"

# rsync with progress
rsync -avP --no-perms --no-owner --no-group "$SRC/" "$DST/"

echo ""
echo "Done. '$NAME' is now on elk-local."
echo "The overlay will serve the local copy immediately."
echo ""
echo "When ready, manually delete from wolf:"
echo "  ssh wolf rm -rf '/mnt/storage/media/$CATEGORY/$NAME'"
