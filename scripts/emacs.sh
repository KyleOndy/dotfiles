#!/usr/bin/env bash

# this script is designed to be called from $EDITOR. Try to connect to
# emacsclient, and if that fails, just open emacs.
emacsclient -create-frame --nw --alternate-editor="" "$@"
