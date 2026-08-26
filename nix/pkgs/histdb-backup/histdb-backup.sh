# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/histdb-backup/default.nix).
#
# Snapshot the zsh-histdb database somewhere durable.
#
# Copying the database file is not enough. Every interactive shell holds a
# sqlite3 connection open for the life of the session, and a live reader stops
# the WAL from checkpointing, so the .db file on its own trails the real
# history by days. VACUUM INTO reads through the WAL and writes a consistent
# standalone database.
#
# The destination is overwritten every run. Its history is the ZFS snapshot
# history of the dataset it lands in, so there is no rotation here.

readonly DB="${HISTDB_FILE:-$HOME/.histdb/zsh-history.db}"
readonly DEST="${1:?usage: histdb-backup <directory|[user@]host:directory>}"

host="$(uname -n)"
readonly NAME="${host%%.*}.db"

if [ ! -e "$DB" ]; then
	echo "histdb-backup: no database at $DB, nothing to back up"
	exit 0
fi

# Staged inside the destination when it is local, so the publish is a rename
# on one filesystem and a snapshot can never catch a half-written database.
if [ "${DEST#*:}" != "$DEST" ]; then
	staging="$(mktemp -d)"
	trap 'rm -rf "$staging"' EXIT
	snapshot="$staging/$NAME"
else
	mkdir -p "$DEST"
	snapshot="${DEST%/}/.$NAME.tmp"
	trap 'rm -f "$snapshot"' EXIT
	rm -f "$snapshot"
fi
readonly snapshot

sqlite3 "$DB" "VACUUM INTO '$snapshot'"
rows="$(sqlite3 "$snapshot" 'select count(*) from history;')"
readonly rows

if [ "${DEST#*:}" != "$DEST" ]; then
	rsync -a --mkpath "$snapshot" "${DEST%/}/$NAME"
else
	mv -f "$snapshot" "${DEST%/}/$NAME"
fi

echo "histdb-backup: $rows commands -> ${DEST%/}/$NAME"
