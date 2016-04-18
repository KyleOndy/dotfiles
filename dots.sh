#!/usr/bin/env bash
set -eu
BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"


for d in `find "$BASE_DIR/apps/" -maxdepth 1 -mindepth 1 -type d`
do
	echo $d
	cp -fav --symbolic-link $d/. ~/
done
