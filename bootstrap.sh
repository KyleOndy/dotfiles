#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

apt-get update
apt-get install -y \
    curl \
    gnupg2

curl /tmp/install.sh https://raw.githubusercontent.com/KyleOndy/dotfiles/install_script/install.sh > /tmp/install.sh
#curl -o /tmp/install.sh.asc https://raw.githubusercontent.com/KyleOndy/dotfiles/install_script/install.sh.asc
#gpg2 --verify install.sh

chmod +x ./install.sh
./install.sh sources