#!/usr/bin/env bash
set -euo pipefail

KEYID="kyle@ondy.org"

printf "expire
100d
key 1
expire
100d
key 1
key 2
expire
100d
key 2
key 3
expire
100d
save
" | gpg --batch --command-fd 0 --status-fd 2 --edit-key $KEYID

# backup keys
dte=$(date +"%Y-%m-%d")
mkdir "$GNUPGHOME/$dte"
gpg --armor --export-secret-keys $KEYID >"$GNUPGHOME/$dte/secret.key"
gpg --armor --export-secret-subkeys $KEYID >"$GNUPGHOME/$dte/secret_sub.key"
gpg --armor --export $KEYID >"$GNUPGHOME/$dte/public.key"

# TODO: make this noninteracitve
gpg --generate-revocation "$KEYID" >"${GNUPGHOME}/${dte}/revocation.key"

gpg --list-key "$KEYID"
echo "GNUPGHOME: $GNUPGHOME"
echo "EXPORTED (to be backed up):  $GNUPGHOME/$dte"
