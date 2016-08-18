#!/usr/bin/env bash
set -eu

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# what programs are we missing?
eval $BASE_DIR/check.sh | grep missing

# if we do not have a local config file, create an empty one
FISH_CONFIG_DIR="$HOME/.config/fish"
LOCAL_FISH_CONFIG="$FISH_CONFIG_DIR/config.fish.local"
if [ ! -f $LOCAL_FISH_CONFIG ]; then
  mkdir -p $FISH_CONFIG_DIR
  touch $LOCAL_FISH_CONFIG
fi

# Lets symlink some files!
for d in `find "$BASE_DIR/apps/" -maxdepth 1 -mindepth 1 -type d`
do
  cp -fa --symbolic-link $d/. ~/
done

# fix some off permission of gpg
chown $(whoami):$(whoami) ~/.gnupg/gpg.conf
chmod 600 ~/.gnupg/*
chmod 700 ~/.gnupg


echo "Setting fish as default shell"
chsh -s $(which fish) $(whoami)

fish
