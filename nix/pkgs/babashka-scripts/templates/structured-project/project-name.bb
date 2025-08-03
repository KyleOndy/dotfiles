#!/usr/bin/env bb

(require '[project-name.cli :as cli])

(apply cli/-main *command-line-args*)