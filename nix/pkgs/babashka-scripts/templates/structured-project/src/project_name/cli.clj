(ns project-name.cli
  "Command line interface for project-name"
  (:require
    [clojure.tools.cli :as cli]
    [project-name.core :as core]))


(def cli-spec
  {:input {:desc "Input file or directory"
           :alias :i
           :required true}
   :output {:desc "Output file or directory"
            :alias :o}
   :verbose {:desc "Verbose output"
             :alias :v}
   :help {:desc "Show help"
          :alias :h}})


(defn print-help
  [summary]
  (println "project-name - Brief description")
  (println)
  (println "Usage:")
  (println "  project-name [options] <args>")
  (println)
  (println "Options:")
  (println summary)
  (println)
  (println "Examples:")
  (println "  project-name -i input.txt -o output.txt"))


(defn -main
  [& args]
  (let [{:keys [options arguments errors summary]} (cli/parse-opts args cli-spec)]
    (cond
      (:help options)
      (do (print-help summary)
          (System/exit 0))

      errors
      (do (println "Error:" (first errors))
          (println)
          (print-help summary)
          (System/exit 1))

      :else
      (try
        (core/run options arguments)
        (catch Exception e
          (println "Error:" (.getMessage e))
          (System/exit 1))))))
