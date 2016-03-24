#!/usr/bin/env fish

set BASE_DIR (cd (dirname (status -f)); and pwd)

eval $BASE_DIR/check.sh | grep missing
eval $BASE_DIR/dots.sh > /dev/null
. "$HOME/.config/fish/config.fish"
