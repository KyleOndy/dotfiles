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
#
# With TEXTFILE_DIR set, a run that lands a snapshot also writes
# histdb_backup.prom there for node_exporter. Every other exit, including the
# exit 0 for a missing database, leaves the previous file alone, so the
# timestamp's age is the age of the newest copy at the destination.

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
	# Into the directory, not onto the file: rsync 3.5.0 under rrsync fails to
	# replace a file named as the destination ("delete_file: unlink(4) failed").
	# DEST is passed unchanged because rrsync rejects "./" as unsafe while
	# accepting ".".
	rsync -a --mkpath "$snapshot" "$DEST"
else
	mv -f "$snapshot" "${DEST%/}/$NAME"
fi

echo "histdb-backup: $rows commands -> ${DEST%/}/$NAME"

# mktemp rather than a fixed name: on NixOS the directory is shared and
# sticky (monitoring-stack/node_exporter.nix). node_exporter reads only
# *.prom, so the temporary file is never scraped half-written.
if [ -n "${TEXTFILE_DIR:-}" ]; then
	prom="$TEXTFILE_DIR/histdb_backup.prom"
	tmp="$(mktemp "$prom.XXXXXX")"
	{
		echo '# HELP histdb_backup_last_success_timestamp_seconds Unix time histdb-backup last landed a snapshot at its destination'
		echo '# TYPE histdb_backup_last_success_timestamp_seconds gauge'
		echo "histdb_backup_last_success_timestamp_seconds $(date +%s)"
		echo '# HELP histdb_backup_rows Rows in the history table of the last snapshot landed'
		echo '# TYPE histdb_backup_rows gauge'
		echo "histdb_backup_rows $rows"
	} >"$tmp"
	chmod 0644 "$tmp"
	mv -f "$tmp" "$prom"
fi
