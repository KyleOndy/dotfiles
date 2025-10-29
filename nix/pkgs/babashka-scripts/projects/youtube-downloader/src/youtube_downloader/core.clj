(ns youtube-downloader.core
  "Main orchestration logic for YouTube downloader"
  (:require
    [clojure.string :as str]
    [common.logging :as log]
    [common.metrics-textfile :as textfile]
    [common.process :as proc]
    [youtube-downloader.anti-bot :as anti-bot]
    [youtube-downloader.cleaner :as cleaner]
    [youtube-downloader.config :as config]
    [youtube-downloader.downloader :as dl]
    [youtube-downloader.observability :as obs]))


(defn print-banner
  "Print startup banner with configuration info"
  [config]
  (let [version (try
                  (if-let [build-version (resolve '*build-version*)]
                    @build-version
                    "dev")
                  (catch Exception _ "dev"))
        yt-dlp-version (try
                         (str/trim (:out (proc/run-command ["yt-dlp" "--version"]
                                                           :throw? false
                                                           :timeout 5000)))
                         (catch Exception _ "unknown"))]
    (log/info "YouTube Downloader starting"
              {:version version
               :yt_dlp_version yt-dlp-version
               :channels (count (:channels config))
               :media_dir (:media-dir config)
               :archive_exists (:archive-exists? config)
               :dry_run (boolean (:dry-run config))})))


(defn print-channel-summary
  "Print summary of channel configurations"
  [channels]
  (log/info "Channel configuration loaded"
            {:total_channels (count channels)
             :channels (mapv #(select-keys % [:name :max-videos :download-shorts]) channels)}))


(defn download-all-channels
  "Download videos from all configured channels"
  [config]
  (let [{:keys [channels sleep-between-channels]} config
        shuffled-channels (anti-bot/shuffle-channels channels)
        total-channels (count shuffled-channels)]

    (log/info "Starting channel downloads"
              {:total_channels total-channels
               :processing_order (mapv :name shuffled-channels)})

    (loop [remaining-channels shuffled-channels
           channel-index 0
           results []]

      (if (empty? remaining-channels)
        ;; All channels processed
        results

        (let [current-channel (first remaining-channels)
              rest-channels (rest remaining-channels)

              ;; Download from current channel
              start-time (System/currentTimeMillis)
              result (dl/download-channel current-channel config)
              duration-seconds (/ (- (System/currentTimeMillis) start-time) 1000.0)

              new-results (conj results (assoc result
                                               :channel (:name current-channel)
                                               :max-videos (:max-videos current-channel)
                                               :duration-seconds duration-seconds))

              ;; Calculate delay to next channel
              delay-seconds (anti-bot/calculate-channel-delay
                              channel-index
                              total-channels
                              sleep-between-channels)]

          ;; Record metrics for this channel
          (obs/record-channel-duration (:name current-channel) duration-seconds)

          ;; Sleep between channels (unless it's the last one)
          (when (and (seq rest-channels)
                     (not (:dry-run config)))
            (log/debug "Sleeping before next channel" {:seconds delay-seconds})
            (Thread/sleep (* 1000 delay-seconds)))

          (recur rest-channels (inc channel-index) new-results))))))


(defn print-results-summary
  "Print summary of download results"
  [results config]
  (let [successful (filter #(zero? (:exit %)) results)
        failed (filter #(not (zero? (:exit %))) results)
        new-downloads (cleaner/count-total-videos (:temp-dir config))
        failed-details (when (seq failed)
                         (mapv #(select-keys % [:channel :exit :error-type]) failed))]
    (log/info "Download session summary"
              {:total_processed (count results)
               :successful (count successful)
               :failed (count failed)
               :new_files new-downloads
               :failed_channels failed-details})

    ;; Update metrics
    (obs/update-temp-files-count new-downloads)
    (obs/record-videos-processed new-downloads)))


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
  (log/log-exception error "Fatal error occurred" {:data_dir (:data-dir config)})

  ;; Log error to file for compatibility
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
  (let [session-start (System/currentTimeMillis)]
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

        ;; Always show channel summary for systemd logs
        (print-channel-summary (:channels config))

        ;; Download from all channels
        (let [results (download-all-channels config)]

          ;; Print results
          (print-results-summary results config)

          ;; Cleanup
          (log/info "Starting post-download cleanup")
          (cleaner/quick-cleanup config)

          ;; Record session metrics
          (let [session-duration (/ (- (System/currentTimeMillis) session-start) 1000.0)]
            (obs/record-session-duration session-duration)
            (obs/update-last-run))

          ;; Write metrics to textfile for node_exporter
          (textfile/write-service-metrics "youtube-downloader")

          (log/info "Download session completed successfully")
          results))

      (catch Exception e
        (handle-error e (or config-override {}))
        ;; Still try to write metrics even on error
        (try
          (textfile/write-service-metrics "youtube-downloader")
          (catch Exception _))
        (System/exit 1)))))


(defn maintenance-mode
  "Run in maintenance mode (cleanup only)"
  []
  (try
    (let [config (config/from-env)]
      (log/info "Starting maintenance mode")
      (cleaner/maintenance-cleanup config)
      (log/info "Maintenance completed"))
    (catch Exception e
      (handle-error e {})
      (System/exit 1))))


(defn dry-run-mode
  "Run in dry-run mode to test configuration"
  []
  (run-download-session :config-override {:dry-run true}))
