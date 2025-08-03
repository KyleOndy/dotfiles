(ns nix-closure-diff.core
  "Main coordination logic for nix closure comparison"
  (:require
    [nix-closure-diff.cli :as cli]
    [nix-closure-diff.comparison :as comp]
    [nix-closure-diff.git :as git]
    [nix-closure-diff.nix :as nix]
    [nix-closure-diff.report :as report]))


(defn validate-environment
  "Validate that all required tools are available"
  []
  (println "Validating environment...")
  (git/ensure-clean-state)
  (nix/validate-nix-available)
  (println "✓ Environment validation passed"))


(defn process-commits
  "Process both commits and generate comparison data"
  [commit-old commit-new systems verbose?]
  (println (str "Comparing commits: " commit-old " → " commit-new))
  (println (str "Systems to process: " (clojure.string/join ", " systems)))

  (git/validate-commits commit-old commit-new)

  (let [repo-path (git/get-repo-root)]
    (when verbose?
      (println (str "Repository path: " repo-path)))

    (println "\n=== Building old system closures ===")
    (let [old-data (nix/get-all-systems-packages repo-path commit-old systems)]
      (when verbose?
        (doseq [[system data] old-data]
          (if (:error data)
            (println (str "❌ " system ": " (:error data)))
            (println (str "✓ " system ": " (:package-count data) " packages")))))

      (println "\n=== Building new system closures ===")
      (let [new-data (nix/get-all-systems-packages repo-path commit-new systems)]
        (when verbose?
          (doseq [[system data] new-data]
            (if (:error data)
              (println (str "❌ " system ": " (:error data)))
              (println (str "✓ " system ": " (:package-count data) " packages")))))

        (println "\n=== Comparing closures ===")
        (let [comparison-data (comp/compare-systems old-data new-data systems)
              summary-stats (comp/calculate-summary-stats comparison-data)]

          (when verbose?
            (println (str "Summary: "
                          (:total-packages-added summary-stats) " added, "
                          (:total-packages-removed summary-stats) " removed, "
                          (:total-version-changes summary-stats) " version changes")))

          {:old-data old-data
           :new-data new-data
           :comparison-data comparison-data
           :summary-stats summary-stats})))))


(defn run-comparison
  "Main function to run the closure comparison"
  [options]
  (let [{:keys [commit-old commit-new systems output format verbose]} options]
    (try
      (validate-environment)

      (let [results (process-commits commit-old commit-new systems verbose)
            {:keys [comparison-data summary-stats]} results
            report-content (report/generate-report format commit-old commit-new
                                                   comparison-data summary-stats)]

        (report/write-report report-content output)

        (println "\n=== Summary ===")
        (println (str "✓ Successfully compared " (:total-systems summary-stats) " systems"))
        (println (str "  - " (:successful-systems summary-stats) " successful builds"))
        (println (str "  - " (:systems-with-errors summary-stats) " systems with errors"))
        (println (str "  - " (:total-packages-added summary-stats) " packages added"))
        (println (str "  - " (:total-packages-removed summary-stats) " packages removed"))
        (println (str "  - " (:total-version-changes summary-stats) " version changes"))

        0) ; exit code 0 for success

      (catch Exception e
        (println (str "❌ Error: " (.getMessage e)))
        (when verbose
          (.printStackTrace e))
        1)))) ; exit code 1 for error

(defn -main
  "Main entry point"
  [& args]
  (let [{:keys [options exit-message ok?]} (cli/validate-args args)]
    (if exit-message
      (do
        (println exit-message)
        (System/exit (if ok? 0 1)))
      (let [exit-code (run-comparison options)]
        (System/exit exit-code)))))
