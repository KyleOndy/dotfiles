#!/usr/bin/env bash
set -e

for d in `find \`pwd\`/apps/ -maxdepth 1 -mindepth 1 -type d`
do
	echo $d
	cp -frv --symbolic-link $d/. ~/
done
