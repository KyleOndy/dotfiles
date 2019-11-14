#!/usr/bin/env bash

print_help() {
    echo "useage: $0 {string}"
    echo -e "\tto search only ./home and ./hosts"
}

if [[ $# -eq 0 ]] ; then
    print_help
fi

grep --color -ri "$@" ./home ./hosts
