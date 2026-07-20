# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/photos-recall/default.nix).
#
# Pull a subset of the authoritative archive on tiger back to the local
# working set, to work on it. This is a copy, not a move: tiger's archive/
# (and its ZFS snapshots) are untouched, so there is nothing to undo if you
# change your mind.
#
#   photos-recall ARCHIVE_PATH [LOCAL_DEST]
#
#   ARCHIVE_PATH   path relative to tiger's archive/, e.g. 2026/2026_07_04
#   LOCAL_DEST     where to land it under the local library, relative to
#                  $HELIOS_LIBRARY_PATH (default ~/photos). Defaults to
#                  _projects/<basename of ARCHIVE_PATH>.

readonly PHOTOS_DIR="${HELIOS_LIBRARY_PATH:-$HOME/photos}"
readonly TIGER_HOST="tiger"
readonly TIGER_ARCHIVE="/mnt/photos/personal/photos/archive"

if [ $# -lt 1 ]; then
	echo "Usage: photos-recall ARCHIVE_PATH [LOCAL_DEST]" >&2
	exit 1
fi

archive_path="${1%/}"
local_dest="${2:-_projects/$(basename "$archive_path")}"

src="$TIGER_HOST:$TIGER_ARCHIVE/$archive_path/"
dest="$PHOTOS_DIR/$local_dest/"

echo "Recalling $src -> $dest"
mkdir -p "$dest"
rsync -avh --progress "$src" "$dest"

echo "Recall complete. $local_dest is a copy; tiger's archive is untouched."
