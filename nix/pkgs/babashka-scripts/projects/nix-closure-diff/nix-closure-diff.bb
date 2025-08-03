#!/usr/bin/env bb

(require '[nix-closure-diff.core :as core])

(apply core/-main *command-line-args*)