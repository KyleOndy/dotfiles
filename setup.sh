#!/usr/bin/env bash
set -e


if [ -f /etc/debian_version ]; then
  sudo apt-get install vim fish tmux git
else
  echo 'need to modify script to handel this OS'
fi

./dots

