#!/usr/bin/env bb

(require '[roku-transcode.cli :as cli])

(apply cli/-main *command-line-args*)