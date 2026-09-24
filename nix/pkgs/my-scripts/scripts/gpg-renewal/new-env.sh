#!/usr/bin/env bash

# Exports GNUPGHOME into the caller, so it only works sourced; `return` rather
# than `exit` below, which would close the caller's shell.
if ! (return 0 2>/dev/null); then
	echo "usage: . new-env.sh <gpg dir>" >&2
	exit 1
fi
if [[ $# -ne 1 ]]; then
	echo "usage: . new-env.sh <gpg dir>" >&2
	return 1
fi

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
# why doesn't this just work?
echo "pinentry-program $(which pinentry-curses)" >"$GNUPGHOME/gpg-agent.conf"

gpg --import "$1/secret.key"
#gpg --import "$1/secret_sub.key"
gpg --list-key
