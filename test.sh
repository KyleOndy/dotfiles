#!/usr/bin/env bash

set -euo pipefail

ERRORS=()

for f in $(find . -type f -not -iwholename '*.git*' | sort -u); do
  if file "$f" | grep --quiet shell; then {
    shellcheck "$f" && echo "[OK]: sucesfully linted $f"
    } || {
    ERRORS+=("$f")
    }
  fi
done

if [ ${#ERRORS[@]} -eq 0 ]; then
  echo "No errors, yay!"
else
  echo "These files failed shellcheck: ${ERRORS[*]}"
  exit 1
fi
