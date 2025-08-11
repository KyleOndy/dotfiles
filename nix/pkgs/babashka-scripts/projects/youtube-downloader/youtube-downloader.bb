#!/usr/bin/env bb

(require '[youtube-downloader.cli :as cli])

(apply cli/-main *command-line-args*)