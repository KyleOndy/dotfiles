#!/usr/bin/env bash
set -e

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

"$BASE_DIR/check.sh"
"$BASE_DIR/dots.sh"
