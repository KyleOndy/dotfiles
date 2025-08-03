(ns nix-closure-diff.cli
  "Command line interface for nix closure comparison"
  (:require
    [clojure.string :as str]
    [clojure.tools.cli :as cli]))


(def cli-options
  [["-c" "--commit-old COMMIT" "Old commit hash to compare from"
    :default "a27a533e"]
   ["-n" "--commit-new COMMIT" "New commit hash to compare to"
    :default "beddaecc"]
   ["-s" "--systems SYSTEMS" "Comma-separated list of systems to compare"
    :default ["dino" "cheetah" "tiger"]
    :parse-fn #(str/split % #",")]
   ["-o" "--output OUTPUT" "Output file for the report"
    :default "closure-comparison-report.md"]
   ["-f" "--format FORMAT" "Output format (markdown, json)"
    :default "markdown"]
   ["-v" "--verbose" "Enable verbose output"]
   ["-h" "--help" "Show this help message"]])


(defn usage
  [options-summary]
  (->> ["Nix Closure Comparison Tool"
        ""
        "Usage: bb nix-closure-diff.bb [options]"
        ""
        "Options:"
        options-summary
        ""
        "Examples:"
        "  bb nix-closure-diff.bb                                    # Compare default commits"
        "  bb nix-closure-diff.bb -c abc123 -n def456               # Compare specific commits"
        "  bb nix-closure-diff.bb -s dino,tiger -o my-report.md     # Compare specific systems"
        ""]
       (str/join \newline)))


(defn error-msg
  [errors]
  (str "Error parsing command line arguments:\n"
       (str/join \newline errors)))


(defn validate-args
  "Validate command line arguments"
  [args]
  (let [{:keys [options arguments errors summary]} (cli/parse-opts args cli-options)]
    (cond
      (:help options)
      {:exit-message (usage summary) :ok? true}

      errors
      {:exit-message (error-msg errors)}

      :else
      {:options options})))


(defn exit
  [status msg]
  (println msg)
  (System/exit status))
