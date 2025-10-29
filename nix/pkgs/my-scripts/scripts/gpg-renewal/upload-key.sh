#!/usr/bin/env bash
set -euo pipefail

KEYID="3C799D26057B64E6D907B0ACDB0E3C33491F91C9"

# upload key
gpg --send-key $KEYID
gpg --keyserver pgp.mit.edu --send-key $KEYID
gpg --keyserver keys.gnupg.net --send-key $KEYID
gpg --keyserver hkps://keyserver.ubuntu.com:443 --send-key $KEYID
