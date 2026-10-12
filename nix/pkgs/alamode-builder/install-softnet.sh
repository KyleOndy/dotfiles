#!/usr/bin/env bash
set -euo pipefail

readonly action=$1
readonly source=$2
readonly parent=$3
readonly directory="$parent/alamode-builder"
readonly target="$directory/softnet"

fail() {
	echo "alamode-builder: $*" >&2
	exit 1
}

no_acl() {
	local listing
	listing=$(/bin/ls -lde "$1") || return 1
	[[ $listing != *$'\n'* ]]
}

check_directory() {
	local mode
	[[ ! -L $1 && -d $1 ]] || fail "Not a regular directory: $1"
	[[ $(stat -c %u "$1") == "$EUID" ]] || fail "Unexpected directory owner: $1"
	mode=$(stat -c %a "$1")
	(((8#$mode & 0022) == 0)) || fail "Directory permits untrusted writes: $1"
	no_acl "$1" || fail "Directory has an ACL: $1"
}

[[ $action == install || $action == remove ]] || fail "Expected install or remove"
if [[ ! -e $parent && ! -L $parent ]]; then
	[[ $action == install ]] || exit 0
	install -d -m 0755 "$parent"
fi
check_directory "$parent"
if [[ ! -e $directory && ! -L $directory ]]; then
	[[ $action == install ]] || exit 0
	install -d -m 0755 "$directory"
fi
check_directory "$directory"
[[ ! -L $target ]] || fail "Refusing helper symlink: $target"
[[ ! -e $target || -f $target ]] || fail "Not a regular helper: $target"

if [[ $action == remove ]]; then
	rm -f -- "$target"
	# Other files may be retained by the operator; only this helper is managed.
	rmdir --ignore-fail-on-non-empty -- "$directory"
	exit 0
fi

[[ -f $source && ! -L $source ]] || fail "Not a regular source: $source"
group=$(id -g)
readonly group
if [[ -f $target ]] && cmp -s -- "$source" "$target" &&
	[[ $(stat -c '%u:%g:%a' "$target") == "$EUID:$group:4755" ]] && no_acl "$target"; then
	exit 0
fi

staging=$(mktemp -d "$directory/.install.XXXXXXXX")
readonly staging
trap 'rm -f -- "$staging/softnet"; rmdir -- "$staging"' EXIT
install -o "$EUID" -g "$group" -m 4755 -- "$source" "$staging/softnet"
mv -fT -- "$staging/softnet" "$target"
