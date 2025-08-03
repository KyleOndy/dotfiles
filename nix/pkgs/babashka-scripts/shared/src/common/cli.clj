(ns common.cli
  "Common CLI utilities for babashka scripts"
  (:require
    [clojure.string :as str]
    [clojure.tools.cli :as cli]))


(defn parse-args
  "Parse command line arguments with common options included"
  [args cli-spec & {:keys [include-common?] :or {include-common? true}}]
  (let [common-spec (when include-common?
                      {:help {:desc "Show help"
                              :alias :h}
                       :verbose {:desc "Verbose output"
                                 :alias :v}})
        full-spec (merge common-spec cli-spec)]
    (cli/parse-opts args full-spec)))


(defn print-help
  "Print help message with usage"
  [program-name description options-summary & {:keys [examples]}]
  (println (str program-name " - " description))
  (println)
  (println "Usage:")
  (println (str "  " program-name " [options] <args>"))
  (println)
  (println "Options:")
  (println options-summary)
  (when examples
    (println)
    (println "Examples:")
    (doseq [example examples]
      (println (str "  " example)))))


(defn exit-with-help
  "Exit with help message and error code"
  [program-name description options-summary & {:keys [error examples]}]
  (when error
    (println "Error:" error)
    (println))
  (print-help program-name description options-summary :examples examples)
  (System/exit (if error 1 0)))


(defn validate-required-args
  "Validate that required arguments are present"
  [parsed-args required-keys]
  (let [missing (remove #(get-in parsed-args [:options %]) required-keys)]
    (when (seq missing)
      {:error (str "Missing required arguments: " (str/join ", " missing))})))


(defn with-error-handling
  "Wrap a function with standard error handling"
  [f]
  (try
    (f)
    (catch Exception e
      (println "Error:" (.getMessage e))
      (System/exit 1))))
