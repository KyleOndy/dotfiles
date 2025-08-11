(ns youtube-downloader.downloader
  "Core downloading functionality using yt-dlp"
  (:require
   [babashka.fs :as fs]
   [clojure.string :as str]
   [common.process :as proc]
   [youtube-downloader.anti-bot :as anti-bot]
   [youtube-downloader.config :as config]))

(defn build-channel-filters
  "Build yt-dlp match filters based on channel configuration"
  [channel-config]
  (let [filters (cond-> []
                  ;; Always skip private videos
                  true (conj "!is_private")

                  ;; Skip shorts if not wanted
                  (not (:download-shorts channel-config))
                  (conj "duration>60" "original_url!*=/shorts/"))]

    (when (seq filters)
      (str/join " & " filters))))

(defn build-yt-dlp-command
  "Build the yt-dlp command with all options"
  [channel-config global-config]
  (let [channel-url (str "https://www.youtube.com/" (:name channel-config))
        archive-file (config/channel-archive-path (:data-dir global-config) (:name channel-config))
        output-template (str (:temp-dir global-config)
                             "/%(uploader)s/%(upload_date)s - %(uploader)s - %(title)s [%(id)s].%(ext)s")

        ;; Base command
        base-cmd ["yt-dlp" channel-url]

        ;; Core options
        core-opts ["--download-archive" archive-file
                   "--prefer-free-formats"
                   "--format" "bestvideo[format_note!*=Premium]+bestaudio/best"
                   "--ignore-errors"
                   "--mark-watched"
                   "--write-auto-sub"
                   "--embed-subs"
                   "--embed-metadata"
                   "--parse-metadata" "%(title)s:%(title)s"
                   "--compat-options" "no-live-chat"
                   "--playlist-end" (str (:max-videos channel-config))
                   "--output" output-template]

        ;; Filters
        filter-opts (when-let [filters (build-channel-filters channel-config)]
                      ["--match-filter" filters])

        ;; Anti-bot options
        stealth-opts (anti-bot/build-stealth-args (:data-dir global-config))]

    (concat base-cmd core-opts filter-opts stealth-opts)))

(defn parse-download-error
  "Parse yt-dlp error output to determine the issue"
  [stderr]
  (let [stderr-lower (str/lower-case stderr)]
    (cond
      ;; Network/connection issues - retryable
      (some #(str/includes? stderr-lower %)
            ["connection", "timeout", "network", "dns", "resolve", "temporary failure"])
      {:type :network :retry? true}

      ;; Rate limiting - retryable  
      (some #(str/includes? stderr-lower %) ["429", "rate limit", "too many requests"])
      {:type :rate-limit :retry? true}

      ;; Access/permission issues - not retryable
      (str/includes? stderr-lower "members only")
      {:type :members-only :retry? false}

      (str/includes? stderr-lower "private video")
      {:type :private :retry? false}

      (str/includes? stderr-lower "copyright")
      {:type :copyright :retry? false}

      ;; Content issues - not retryable
      (some #(str/includes? stderr-lower %) ["unavailable", "not available", "removed"])
      {:type :unavailable :retry? false}

      (some #(str/includes? stderr-lower %) ["no video", "no such", "not found"])
      {:type :not-found :retry? false}

      ;; Age restricted - not retryable
      (str/includes? stderr-lower "age")
      {:type :age-restricted :retry? false}

      ;; Region blocked - not retryable
      (some #(str/includes? stderr-lower %) ["region", "country", "blocked"])
      {:type :geo-blocked :retry? false}

      ;; Format/extraction issues - possibly retryable
      (some #(str/includes? stderr-lower %) ["format", "extract", "parse"])
      {:type :extraction :retry? true}

      ;; Default case
      :else
      {:type :unknown :retry? (anti-bot/should-retry? stderr)})))

(defn extract-video-id
  "Extract video ID from error message if present"
  [stderr]
  (when-let [match (re-find #"\[youtube\] ([A-Za-z0-9_-]{11}):" stderr)]
    (second match)))

(defn add-to-skip-list
  "Add a video ID to the skip list"
  [data-dir video-id reason]
  (let [skip-file (str data-dir "/skip-list.txt")
        entry (format "%s\t%s\t%s\n"
                      (java.time.Instant/now)
                      video-id
                      reason)]
    (spit skip-file entry :append true)))

(defn download-with-retry
  "Download with retry logic and error handling"
  [channel-config global-config & {:keys [max-attempts]
                                   :or {max-attempts 3}}]
  (let [cmd (build-yt-dlp-command channel-config global-config)]
    (loop [attempt 0]
      (when (:verbose global-config)
        (println (format "  Attempt %d/%d for %s (max %d videos)"
                         (inc attempt)
                         max-attempts
                         (:name channel-config)
                         (:max-videos channel-config))))

      (let [result (if (:dry-run global-config)
                     (do
                       (println "  [DRY RUN] Would execute:" (str/join " " cmd))
                       {:exit 0 :out "Dry run" :err ""})
                     (proc/run-command cmd :throw? false :timeout 600000))]

        (cond
          ;; Success
          (zero? (:exit result))
          (do
            (when (:verbose global-config)
              (println (format "  ✓ Successfully processed %s" (:name channel-config))))
            result)

          ;; Check if we should retry
          (>= attempt (dec max-attempts))
          (do
            (println (format "  ✗ Failed after %d attempts for %s"
                             max-attempts
                             (:name channel-config)))
            result)

          ;; Parse error and decide on retry
          :else
          (let [error-info (parse-download-error (:err result))]
            (if (:retry? error-info)
              (do
                (when (= :rate-limit (:type error-info))
                  (anti-bot/handle-rate-limit (:err result) attempt))
                (Thread/sleep (anti-bot/exponential-backoff attempt))
                (recur (inc attempt)))
              (do
                ;; Non-retryable error - log and skip
                (when-let [video-id (extract-video-id (:err result))]
                  (add-to-skip-list (:data-dir global-config)
                                    video-id
                                    (name (:type error-info))))
                (do
                  (println (format "  ⚠ Skipping due to %s error: %s"
                                   (:type error-info)
                                   (:name channel-config)))
                  ;; Show actual error details for debugging
                  (when (or (:verbose global-config) (= :unknown (:type error-info)))
                    (println (format "  Error details: %s"
                                     (str/replace (:err result) #"\n" " | ")))))
                result))))))))

(defn download-channel
  "Download videos from a single channel"
  [channel-config global-config]
  (println (format "\nProcessing channel: %s" (:name channel-config)))
  (println (format "  Settings: max=%d videos, shorts=%s"
                   (:max-videos channel-config)
                   (:download-shorts channel-config)))

  ;; Ensure temp directory exists
  (fs/create-dirs (:temp-dir global-config))

  ;; Download with retry logic
  (let [result (download-with-retry channel-config global-config)]

    ;; Random delay between videos within the channel
    (when (and (zero? (:exit result))
               (not (:dry-run global-config)))
      (let [delay-ms (anti-bot/random-delay
                      (get-in global-config [:sleep-between-videos :min])
                      (get-in global-config [:sleep-between-videos :max]))]
        (when (:verbose global-config)
          (println (format "  Sleeping %d seconds between videos..."
                           (/ delay-ms 1000))))))

    result))

(defn count-downloads
  "Count new downloads in temp directory"
  [temp-dir]
  (count (fs/glob temp-dir "**/*.{mp4,webm,mkv}")))
