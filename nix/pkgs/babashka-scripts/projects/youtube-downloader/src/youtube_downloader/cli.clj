(ns youtube-downloader.cli
  "Command-line interface for YouTube downloader"
  (:require
    [babashka.cli :as cli]
    [clojure.string :as str]
    [youtube-downloader.core :as core]))


(def cli-spec
  "CLI options specification"
  {:help {:desc "Show help"
          :alias :h}
   :verbose {:desc "Enable verbose output"
             :alias :v}
   :dry-run {:desc "Show what would be done without executing"
             :alias :d}
   :maintenance {:desc "Run maintenance cleanup only"
                 :alias :m}
   :config-test {:desc "Test configuration and exit"
                 :alias :t}
   :channels {:desc "Override channels (comma-separated @channel names)"
              :alias :c}
   :max-videos {:desc "Override max videos per channel"
                :alias :n}})


(defn show-help
  "Display help message"
  []
  (println "youtube-downloader - Babashka-powered YouTube video downloader")
  (println)
  (println "A bot-detection-aware YouTube downloader with per-channel configuration")
  (println "and conservative defaults to minimize API calls.")
  (println)
  (println "Usage:")
  (println "  youtube-downloader [options]")
  (println)
  (println "Options:")
  (println "  -h, --help          Show this help")
  (println "  -v, --verbose       Enable verbose output")
  (println "  -d, --dry-run       Show what would be done without executing")
  (println "  -m, --maintenance   Run maintenance cleanup only")
  (println "  -t, --config-test   Test configuration and exit")
  (println "  -c, --channels      Override channels (e.g., '@channel1,@channel2')")
  (println "  -n, --max-videos    Override max videos per channel")
  (println)
  (println "Environment Variables:")
  (println "  YT_MEDIA_DIR               Target directory for videos")
  (println "  YT_DATA_DIR                Data directory for archives/logs")
  (println "  YT_TEMP_DIR                Temporary download directory")
  (println "  YT_CHANNELS                JSON array of channel configurations")
  (println "  YT_DOWNLOAD_SHORTS_DEFAULT Global default for downloading shorts")
  (println "  YT_MAX_VIDEOS_DEFAULT      Default max videos per channel (default: 5)")
  (println "  YT_MAX_VIDEOS_INITIAL      Max videos on first run (default: 30)")
  (println "  YT_SLEEP_BETWEEN_CHANNELS  Seconds between channels (default: 60)")
  (println "  YT_DRY_RUN                 Set to 'true' for dry run")
  (println "  YT_VERBOSE                 Set to 'true' for verbose output")
  (println)
  (println "Examples:")
  (println "  # Normal operation (uses environment configuration)")
  (println "  youtube-downloader")
  (println)
  (println "  # Verbose dry run")
  (println "  youtube-downloader --verbose --dry-run")
  (println)
  (println "  # Override specific channels")
  (println "  youtube-downloader --channels '@TechChannel,@NewsChannel'")
  (println)
  (println "  # Test configuration")
  (println "  youtube-downloader --config-test --verbose")
  (println)
  (println "  # Maintenance mode only")
  (println "  youtube-downloader --maintenance")
  (println)
  (println "Channel Configuration Format:")
  (println "  Channels can be configured as simple strings or objects:")
  (println "  Simple: \"@channelname\"")
  (println "  Complex: {\"name\": \"@channelname\", \"max_videos\": 10, \"download_shorts\": true}")
  (println)
  (println "Default Behavior:")
  (println "  - Checks only 5 most recent videos per channel (conservative)")
  (println "  - Does not download YouTube Shorts by default")
  (println "  - Uses random delays between channels to avoid bot detection")
  (println "  - Respects yt-dlp download archive to avoid re-downloads"))


(defn parse-channels-override
  "Parse comma-separated channel names from CLI"
  [channels-str]
  (when channels-str
    (->> (str/split channels-str #",")
         (map str/trim)
         (filter seq)
         (map #(hash-map :name %)))))


(defn test-configuration
  "Test configuration and display results"
  [verbose]
  (try
    (let [config (youtube-downloader.config/from-env)
          validation (youtube-downloader.config/validate-config config)]

      (println "=== Configuration Test ===")

      (if validation
        (do
          (println "❌ Configuration Error:")
          (println (str "   " (:error validation)))
          (System/exit 1))

        (do
          (println "✅ Configuration Valid")
          (println)
          (println "Settings:")
          (println (format "  Media Dir:       %s" (:media-dir config)))
          (println (format "  Data Dir:        %s" (:data-dir config)))
          (println (format "  Temp Dir:        %s" (:temp-dir config)))
          (println (format "  Archive Exists:  %s" (:archive-exists? config)))
          (println (format "  Channels:        %d" (count (:channels config))))
          (println)

          (when verbose
            (println "Channel Details:")
            (doseq [{:keys [name max-videos download-shorts]} (:channels config)]
              (println (format "  %-25s max=%2d shorts=%s"
                               name max-videos download-shorts)))
            (println))

          (println "✅ Configuration test passed"))))

    (catch Exception e
      (println "❌ Configuration Test Failed:")
      (println (str "   " (.getMessage e)))
      (when verbose
        (.printStackTrace e))
      (System/exit 1))))


(defn -main
  "Main entry point"
  [& args]
  (let [options (cli/parse-opts args {:spec cli-spec})]

    (cond
      ;; Show help
      (:help options)
      (do
        (show-help)
        (System/exit 0))

      ;; Config test mode
      (:config-test options)
      (test-configuration (:verbose options))

      ;; Maintenance mode
      (:maintenance options)
      (core/maintenance-mode)

      ;; Regular operation
      :else
      (let [;; Build configuration overrides from CLI options
            config-override (cond-> {}
                              (:verbose options) (assoc :verbose true)
                              (:dry-run options) (assoc :dry-run true)
                              (:channels options) (assoc :channels
                                                         (parse-channels-override (:channels options)))
                              (:max-videos options) (assoc :max-videos-default
                                                           (Integer/parseInt (:max-videos options))))]

        (core/run-download-session :config-override config-override)))))
