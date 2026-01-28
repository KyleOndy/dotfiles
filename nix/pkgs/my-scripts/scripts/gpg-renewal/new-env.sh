#!/usr/bin/env bash

if [[ $# -ne 1 ]]; then
	echo "usage: $0 <gpg dir>"
	exit 1
fi

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
# why doesn't this just work?
echo "pinentry-program $(which pinentry-curses)" >"$GNUPGHOME/gpg-agent.conf"

gpg --import "$1/secret.key"
#gpg --import "$1/secret_sub.key"
gpg --list-key
