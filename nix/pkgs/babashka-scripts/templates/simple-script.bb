#!/usr/bin/env bb

(ns script-name
  "Brief description of what this script does"
  (:require [common.cli :as cli]
            [common.fs :as fs]
            [common.process :as proc]))

;; CLI specification
(def cli-spec
  {:input {:desc "Input file or directory"
           :alias :i
           :required true}
   :output {:desc "Output file or directory"
            :alias :o}
   :dry-run {:desc "Show what would be done without executing"
             :alias :d}})

(defn process-input
  "Main processing function"
  [input-path output-path opts]
  (when (:verbose opts)
    (println "Processing:" input-path))
  
  ;; Add your logic here
  (if (:dry-run opts)
    (println "Would process" input-path "to" output-path)
    (do
      ;; Actual processing
      (println "Processing complete"))))

(defn -main [& args]
  (let [{:keys [options arguments errors summary]} (cli/parse-args args cli-spec)]
    (cond
      (:help options)
      (cli/exit-with-help "script-name" 
                         "Brief description"
                         summary
                         :examples ["script-name -i input.txt -o output.txt"])
      
      errors
      (cli/exit-with-help "script-name"
                         "Brief description" 
                         summary
                         :error (first errors))
      
      :else
      (cli/with-error-handling
        #(process-input (:input options)
                       (:output options)
                       options)))))

;; Execute when script is run directly
(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))