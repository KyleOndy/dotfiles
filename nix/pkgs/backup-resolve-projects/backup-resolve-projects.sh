# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/backup-resolve-projects/default.nix).
#
# One command that makes every in-flight video project non-single-copy.
# Both trees land on tiger's storage/projects, which sanoid snapshots hourly
# and pika replicates nightly. Nothing pushes that dataset to S3, on purpose:
# see the third scope class in docs/backup-strategy.md.
#
# Two trees, because either one alone restores to nothing useful. ~/resolve
# holds the footage, the shot lists and the stringouts. The project library
# holds the timelines, grades and bin structure that reference them, and
# Resolve keeps it under Application Support rather than in the project
# folder, so backing up the project folder alone loses every edit decision
# ever made. Nothing about the on-disk layout hints at that coupling, which
# is the whole reason this is one command instead of two rsync invocations
# someone has to remember to pair.
#
# Deletes propagate, by design. Clean up a finished project locally and the
# next run removes it from tiger, where it ages out on the retention set in
# tiger/configuration.nix: hourly 24, daily 30, monthly 2, no yearly. So a
# deleted project stays recoverable for about a month and then stops
# consuming a pool that is already at 85%.

readonly RESOLVE_DIR="$HOME/resolve"
readonly LIBRARY_DIR="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Resolve Project Library"
readonly TIGER_HOST="tiger"
readonly TIGER_DEST="/mnt/projects"

# Finder leaves droppings in any tree it browses.
readonly LITTER_EXCLUDES=(
	--exclude ".DS_Store"
	--exclude "._*"
	--exclude ".Spotlight-V100"
	--exclude ".fseventsd"
	--exclude ".TemporaryItems"
	--exclude ".Trashes"
)

# --delete against a source that is missing or empty is not a backup, it is a
# one-command wipe of the copy that exists to survive exactly that mistake.
# tiger's snapshots would still hold the data, but needing them because of
# this script would be an own goal.
require_populated() {
	if [ ! -d "$1" ]; then
		echo "No directory at $1" >&2
		echo "Refusing to mirror a missing source: --delete would empty the copy on $TIGER_HOST." >&2
		exit 1
	fi
	if [ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
		echo "$1 is empty" >&2
		echo "Refusing to mirror an empty source: --delete would empty the copy on $TIGER_HOST." >&2
		exit 1
	fi
}

# --info: progress2 is the only thing that distinguishes a large sync in
# flight from a hung ssh connection, and del names what a cleanup is
# propagating, which is the one destructive thing this script does.
mirror() {
	rsync -a --delete --info=progress2,del "${LITTER_EXCLUDES[@]}" "$1/" "$TIGER_HOST:$2/"
}

# The project library is a live SQLite database. A copy taken while Resolve
# holds it open is torn, and a torn database restores as a corrupt project,
# which is worse than no copy because it still looks like a backup. Checked
# up front rather than at the point of use: the footage sync below can run
# for the better part of an hour, and finding out afterwards that the half
# that matters was skipped is a bad way to spend it.
#
# pgrep comes from macOS at /usr/bin/pgrep. This script only ever installs on
# trex (darwin), and nixpkgs procps is Linux-only, so there is nothing to add
# to runtimeInputs for it.
library_syncable=1
if pgrep -x Resolve >/dev/null 2>&1; then
	library_syncable=0
	echo "DaVinci Resolve is running: the project library will be SKIPPED." >&2
	echo "Syncing $RESOLVE_DIR anyway, since plain files copy safely either way." >&2
	echo >&2
fi

require_populated "$RESOLVE_DIR"
echo "Syncing $RESOLVE_DIR to $TIGER_HOST:$TIGER_DEST/resolve/"
mirror "$RESOLVE_DIR" "$TIGER_DEST/resolve"

if [ "$library_syncable" -eq 0 ]; then
	echo >&2
	echo "Footage is backed up. The project library is NOT: quit Resolve and run this again." >&2
	exit 1
fi

require_populated "$LIBRARY_DIR"
echo "Syncing the Resolve project library to $TIGER_HOST:$TIGER_DEST/resolve-project-library/"
mirror "$LIBRARY_DIR" "$TIGER_DEST/resolve-project-library"
