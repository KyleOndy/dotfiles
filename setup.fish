#!/usr/bin/env fish
set BASE_DIR (cd (dirname (status -f)); and pwd)

eval $BASE_DIR/check.sh | grep missing
eval $BASE_DIR/dots.sh > /dev/null


set LOCAL_FISH_CONFIG "$HOME/.config/fish/config.fish.local"
if test ! -e $LOCAL_FISH_CONFIG
  touch $LOCAL_FISH_CONFIG
end

. "$HOME/.config/fish/config.fish"
