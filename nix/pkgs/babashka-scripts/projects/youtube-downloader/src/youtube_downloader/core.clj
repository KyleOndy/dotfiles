(ns youtube-downloader.core
  "Main orchestration logic for YouTube downloader"
  (:require
   [clojure.string :as str]
   [common.process :as proc]
   [youtube-downloader.anti-bot :as anti-bot]
   [youtube-downloader.cleaner :as cleaner]
   [youtube-downloader.config :as config]
   [youtube-downloader.downloader :as dl]))

(defn print-banner
  "Print startup banner with configuration info"
  [config]
  (let [version (try
                  (if-let [build-version (resolve '*build-version*)]
                    @build-version
                    "dev")
                  (catch Exception _ "dev"))]
    (println (format "=== YouTube Downloader v%s ===" version)))
  (println (format "yt-dlp version: %s"
                   (try
                     (str/trim (:out (proc/run-command ["yt-dlp" "--version"]
                                                       :throw? false
                                                       :timeout 5000)))
                     (catch Exception _ "unknown"))))
  (println (format "Channels configured: %d" (count (:channels config))))
  (println (format "Media directory: %s" (:media-dir config)))
  (println (format "Archive exists: %s" (:archive-exists? config)))
  (when (:dry-run config)
    (println "*** DRY RUN MODE - No actual downloads ***"))
  (when (:verbose config)
    (println "*** VERBOSE MODE ***"))
  (println))

(defn print-channel-summary
  "Print summary of channel configurations"
  [channels]
  (println "Channel Configuration:")
  (doseq [{:keys [name max-videos download-shorts]} channels]
    (println (format "  %-25s max=%2d shorts=%s"
                     name
                     max-videos
                     download-shorts)))
  (println))

(defn download-all-channels
  "Download videos from all configured channels"
  [config]
  (let [{:keys [channels verbose sleep-between-channels]} config
        shuffled-channels (anti-bot/shuffle-channels channels)
        total-channels (count shuffled-channels)]

    (when verbose
      (println (format "Processing %d channels in random order:" total-channels))
      (doseq [ch shuffled-channels]
        (println (format "  %s" (:name ch))))
      (println))

    (println "=== Starting Downloads ===")

    (loop [remaining-channels shuffled-channels
           channel-index 0
           results []]

      (if (empty? remaining-channels)
        ;; All channels processed
        results

        (let [current-channel (first remaining-channels)
              rest-channels (rest remaining-channels)

              ;; Download from current channel
              result (dl/download-channel current-channel config)
              new-results (conj results (assoc result
                                               :channel (:name current-channel)
                                               :max-videos (:max-videos current-channel)))

              ;; Calculate delay to next channel
              delay-seconds (anti-bot/calculate-channel-delay
                             channel-index
                             total-channels
                             sleep-between-channels)]

          ;; Sleep between channels (unless it's the last one)
          (when (and (seq rest-channels)
                     (not (:dry-run config)))
            (when verbose
              (println (format "\nSleeping %d seconds before next channel..." delay-seconds)))
            (Thread/sleep (* 1000 delay-seconds)))

          (recur rest-channels (inc channel-index) new-results))))))

(defn print-results-summary
  "Print summary of download results"
  [results config]
  (println "\n=== Download Summary ===")

  (let [successful (filter #(zero? (:exit %)) results)
        failed (filter #(not (zero? (:exit %))) results)]

    (println (format "Channels processed: %d" (count results)))
    (println (format "Successful: %d" (count successful)))
    (println (format "Failed: %d" (count failed)))

    ;; Show failed channels
    (when (seq failed)
      (println "\nFailed channels:")
      (doseq [{:keys [channel exit]} failed]
        (println (format "  %s (exit code: %d)" channel exit))))

    ;; Count new downloads
    (let [new-downloads (cleaner/count-total-videos (:temp-dir config))]
      (when (pos? new-downloads)
        (println (format "\nNew downloads: %d files" new-downloads))))))

(defn validate-prerequisites
  "Check that required tools are available"
  []
  (let [missing-tools (remove proc/command-exists? ["yt-dlp" "rsync" "du"])]
    (when (seq missing-tools)
      (throw (ex-info (format "Missing required tools: %s"
                              (str/join ", " missing-tools))
                      {:missing-tools missing-tools})))))

(defn handle-error
  "Handle errors gracefully with proper logging"
  [error config]
  (println (format "\n❌ Error: %s" (.getMessage error)))

  (when (:verbose config)
    (println "\nStack trace:")
    (.printStackTrace error))

  ;; Log error to file
  (try
    (spit (str (:data-dir config) "/error.log")
          (format "[%s] %s\n%s\n\n"
                  (java.time.Instant/now)
                  (.getMessage error)
                  (with-out-str (.printStackTrace error)))
          :append true)
    (catch Exception _
      ;; Ignore logging errors
      nil)))

(defn run-download-session
  "Run a complete download session"
  [& {:keys [config-override]}]
  (try
    ;; Load and validate configuration
    (let [config (merge (config/from-env) config-override)]

      ;; Print startup info immediately (before any validation that might fail)
      (print-banner config)

      ;; Validate configuration
      (when-let [error (config/validate-config config)]
        (throw (ex-info (:error error) error)))

      ;; Check prerequisites
      (validate-prerequisites)

      ;; Print additional verbose info
      (when (:verbose config)
        (print-channel-summary (:channels config)))

      ;; Download from all channels
      (let [results (download-all-channels config)]

        ;; Print results
        (print-results-summary results config)

        ;; Cleanup
        (println "\n=== Post-download Cleanup ===")
        (cleaner/quick-cleanup config)

        (println "\n✅ Download session completed")
        results))

    (catch Exception e
      (handle-error e (or config-override {}))
      (System/exit 1))))

(defn maintenance-mode
  "Run in maintenance mode (cleanup only)"
  []
  (try
    (let [config (config/from-env)]
      (println "=== Maintenance Mode ===")
      (cleaner/maintenance-cleanup config)
      (println "✅ Maintenance completed"))
    (catch Exception e
      (handle-error e {})
      (System/exit 1))))

(defn dry-run-mode
  "Run in dry-run mode to test configuration"
  []
  (run-download-session :config-override {:dry-run true :verbose true}))
