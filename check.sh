#!/usr/bin/env sh
set -e
BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

check_program(){

  if is_program_available "$1"; then
    printf '%-12s\t[installed]\n' "$1"
  else
    printf '%-12s\t[missing]\n' "$1"
  fi
}

is_program_available(){
  local p="$1"
  command -v "$p" >/dev/null 2>&1
}

echo "checking programs"

while read PROGRAM
do
  check_program $PROGRAM
done < "$BASE_DIR/programs_to_check.txt"
