#!/usr/bin/env bash

DOTFILES=$HOME/.dotfiles

run() {
REQUIRED_PROGRAMS=( 'fish' 'git' 'gpg2' )
for app in "${REQUIRED_PROGRAMS[@]}"
do
  if ! is_program_available $app; then
    echo "$app is not found"
    echo "Can not contine bootstraping until the above programs are installed"
    exit 1
  fi
done

git clone https://github.com/KyleOndy/dotfiles.git $DOTFILES

cd $DOTFILES

git verify-commit HEAD


if [ "$?" = 0 ]; then
  echo 'Repo looks good'
  ./setup.sh
fi;
}

is_program_available() {
  local p="$1"
  command -v "$p" >/dev/null 2>&1
}

run
