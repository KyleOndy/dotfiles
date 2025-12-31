#!/usr/bin/env bash
set -euo pipefail
set -x

KEYID="kyle@ondy.org"

# need to make a new GPG environment since moving the keys to the cards is a
# destructive action
REAL_GNUPGHOME=$GNUPGHOME
GNUPGHOME=$(mktemp -d)
export GNUPGHOME
cp "$REAL_GNUPGHOME/gpg-agent.conf" "$GNUPGHOME/"

gpg --import "$1/secret.key"
gpg --import "$1/secret_sub.key"
#gpg --card-status
pkill gpg-agent # why?

printf "key 1
keytocard
1
y
key 1
key 2
keytocard
2
y
key 2
key 3
keytocard
3
y
save
" | gpg --batch --command-fd 0 --status-fd 2 --edit-key $KEYID
