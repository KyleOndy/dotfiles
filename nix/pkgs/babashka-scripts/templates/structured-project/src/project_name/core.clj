(ns project-name.core
  "Core functionality for project-name"
  (:require
    [babashka.fs :as fs]
    [clojure.java.io :as io]))


(defn run
  "Main entry point for the application"
  [options arguments]
  (when (:verbose options)
    (println "Running with options:" options)
    (println "Arguments:" arguments))

  ;; Add your core logic here
  (println "Hello from project-name!"))
