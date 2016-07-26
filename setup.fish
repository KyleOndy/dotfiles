#!/usr/bin/env fish
set BASE_DIR (cd (dirname (status -f)); and pwd)

#eval $BASE_DIR/check.sh | grep missing
eval $BASE_DIR/dots.sh > /dev/null


set LOCAL_FISH_CONFIG "$HOME/.config/fish/config.fish.local"
if test ! -e $LOCAL_FISH_CONFIG
  touch $LOCAL_FISH_CONFIG
end

chown (whoami):(whoami) ~/.gnupg/gpg.conf
chmod 600 ~/.gnupg/*
chmod 700 ~/.gnupg

. "$HOME/.config/fish/config.fish"
