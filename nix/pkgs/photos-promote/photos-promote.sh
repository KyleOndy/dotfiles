# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/photos-promote/default.nix).
#
# Push finished assets from the local working set into tiger's authoritative
# archive. This is a copy, not a move: the local source is left in place so
# you can verify the promotion landed before cleaning up _provisional/
# yourself. tiger's routine fan-out (nix/pkgs/photos-fanout) then carries
# archive/ on to S3 Deep Archive.
#
# Deleting the local shoot afterwards does not prune tiger's _provisional/
# copy; backup-photos only mirrors shoots the laptop still holds. Prune that
# copy on tiger directly when you want it gone.
#
#   photos-promote LOCAL_SRC [ARCHIVE_DEST]
#
#   LOCAL_SRC      path relative to $HELIOS_LIBRARY_PATH (default
#                  ~/photos), e.g. "archive/2026-07 Germany and Finland"
#   ARCHIVE_DEST   path relative to tiger's archive/, which is flat and
#                  human-named ("2026-07 Germany and Finland"). Defaults to
#                  the basename of LOCAL_SRC. Naming a shoot is the curation
#                  step, so promoting straight out of _provisional needs
#                  this argument: its YYYY_MM_DD directories are not
#                  archive names.

readonly PHOTOS_DIR="${HELIOS_LIBRARY_PATH:-$HOME/photos}"
readonly TIGER_HOST="tiger"
readonly TIGER_ARCHIVE="/mnt/photos/personal/photos/archive"

if [ $# -lt 1 ]; then
	echo "Usage: photos-promote LOCAL_SRC [ARCHIVE_DEST]" >&2
	exit 1
fi

local_src="${1%/}"
archive_dest="${2:-$(basename "$local_src")}"
archive_dest="${archive_dest%/}"

src="$PHOTOS_DIR/$local_src/"
dest="$TIGER_HOST:$TIGER_ARCHIVE/$archive_dest/"

if [ ! -d "$src" ]; then
	echo "Error: $src does not exist" >&2
	exit 1
fi

echo "Promoting $src -> $dest"
# --mkpath: rsync only ever creates the last component of a destination path
# on its own, so a nested ARCHIVE_DEST needs its parents made. Doing it here
# rather than over ssh keeps the path out of a remote shell, which would
# word-split the spaces every archive name carries.
rsync -avh --mkpath --progress "$src" "$dest"

echo "Promotion complete. $local_src is untouched; delete it yourself once verified."
