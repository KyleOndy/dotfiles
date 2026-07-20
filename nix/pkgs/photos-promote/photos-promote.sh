# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/photos-promote/default.nix).
#
# Push finished assets from the local working set into tiger's authoritative
# archive. This is a copy, not a move: the local source is left in place so
# you can verify the promotion landed before cleaning up _provisional/
# or _projects/ yourself. tiger's routine fan-out (nix/pkgs/photos-fanout)
# then carries archive/ on to S3 Deep Archive and the external HDD.
#
#   photos-promote LOCAL_SRC ARCHIVE_DEST
#
#   LOCAL_SRC      path relative to $HELIOS_LIBRARY_PATH (default
#                  ~/photos), e.g. _projects/family-trip/final or
#                  _provisional/2026/2026_07_04
#   ARCHIVE_DEST   path relative to tiger's archive/, e.g. 2026/2026_07_04

readonly PHOTOS_DIR="${HELIOS_LIBRARY_PATH:-$HOME/photos}"
readonly TIGER_HOST="tiger"
readonly TIGER_ARCHIVE="/mnt/photos/personal/photos/archive"

if [ $# -ne 2 ]; then
	echo "Usage: photos-promote LOCAL_SRC ARCHIVE_DEST" >&2
	exit 1
fi

local_src="${1%/}"
archive_dest="${2%/}"

src="$PHOTOS_DIR/$local_src/"
dest="$TIGER_HOST:$TIGER_ARCHIVE/$archive_dest/"

if [ ! -d "$src" ]; then
	echo "Error: $src does not exist" >&2
	exit 1
fi

echo "Promoting $src -> $dest"
ssh "$TIGER_HOST" mkdir -p "$TIGER_ARCHIVE/$archive_dest"
rsync -avh --progress "$src" "$dest"

echo "Promotion complete. $local_src is untouched; delete it yourself once verified."
