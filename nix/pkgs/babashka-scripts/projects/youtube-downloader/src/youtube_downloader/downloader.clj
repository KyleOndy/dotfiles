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
                  ;; Basic availability filtering - start minimal
                  true (conj "!is_private"
                             "availability=public")

                  ;; Skip shorts if not wanted
                  (not (:download-shorts channel-config))
                  (conj "duration>60" "original_url!*=/shorts/"))]

    (when (seq filters)
      (str/join " & " filters))))

(defn load-skip-list
  "Load video IDs from skip list that should be permanently excluded"
  [data-dir]
  (let [skip-file (str data-dir "/skip-list.txt")
        ;; Only skip permanent failures, not temporary network issues
        permanent-failures #{:unavailable :private :members-only
                             :copyright :not-found :age-restricted
                             :geo-blocked}]
    (if (fs/exists? skip-file)
      (try
        (->> (slurp skip-file)
             str/split-lines
             (map #(str/split % #"\t"))
             ;; Parse format: timestamp\tvideo-id\treason
             (filter #(>= (count %) 3))
             ;; Only include permanent failure types
             (filter #(contains? permanent-failures (keyword (nth % 2))))
             ;; Extract video IDs
             (map second)
             ;; Deduplicate
             distinct
             ;; Limit to recent 100 to avoid command line length issues
             (take 100)
             vec)
        (catch Exception e
          (println (format "Warning: Could not load skip list: %s" (.getMessage e)))
          []))
      [])))

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
                   "--format" "bestvideo+bestaudio/best"
                   "--ignore-errors"
                   "--mark-watched"
                   "--write-auto-sub"
                   "--embed-subs"
                   "--embed-metadata"
                   "--parse-metadata" "%(title)s:%(title)s"
                   "--compat-options" "no-live-chat"
                   "--playlist-end" (str (:max-videos channel-config))
                   "--output" output-template
                   "--print" "before_dl:Downloading: %(title)s [%(id)s]"]

        ;; Build combined filters (channel filters + skip list)
        channel-filters (build-channel-filters channel-config)
        skip-list (load-skip-list (:data-dir global-config))
        skip-filters (when (seq skip-list)
                       (str/join " & " (map #(str "id!='" % "'") skip-list)))
        all-filters (cond
                      (and channel-filters skip-filters)
                      (str channel-filters " & " skip-filters)

                      channel-filters channel-filters
                      skip-filters skip-filters
                      :else nil)

        filter-opts (when all-filters
                      ["--match-filter" all-filters])

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
      ;; Always show attempts for systemd logs
      (println (format "  Attempt %d/%d for %s (max %d videos)"
                       (inc attempt)
                       max-attempts
                       (:name channel-config)
                       (:max-videos channel-config)))

      (let [result (if (:dry-run global-config)
                     (do
                       (println "  [DRY RUN] Would execute:" (str/join " " cmd))
                       {:exit 0 :out "Dry run" :err ""})
                     (proc/run-command cmd :throw? false :timeout 600000))]

        (cond
          ;; Success
          (zero? (:exit result))
          (do
            ;; Always show success for systemd logs
            (println (format "  ✓ Successfully processed %s" (:name channel-config)))
            result)

          ;; Check if we should retry
          (>= attempt (dec max-attempts))
          (do
            (println (format "  ✗ Failed after %d attempts for %s"
                             max-attempts
                             (:name channel-config)))
            ;; Include error info in the result for summary
            (assoc result
                   :error-type (:type (parse-download-error (:err result)))
                   :error-msg (first (str/split-lines (:err result)))))

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
                ;; Always show error details for systemd logs
                (let [error-lines (str/split-lines (:err result))
                      key-error (or (last (filter #(re-find #"ERROR|Error|error" %) error-lines))
                                    (last error-lines))]
                  (println (format "  ⚠ Skipping %s | Type: %s | Error: %s"
                                   (:name channel-config)
                                   (:type error-info)
                                   (str/replace key-error #"\n" " "))))
                (assoc result
                       :error-type (:type error-info)
                       :error-msg (first (str/split-lines (:err result))))))))))))

(defn download-channel
  "Download videos from a single channel"
  [channel-config global-config]
  ;; Single line channel info for systemd logs
  (println (format "\nProcessing %s: max=%d videos, shorts=%s"
                   (:name channel-config)
                   (:max-videos channel-config)
                   (:download-shorts channel-config)))

  ;; Ensure temp directory exists
  (fs/create-dirs (:temp-dir global-config))

  ;; Download with retry logic - yt-dlp handles sleep between actual downloads
  (download-with-retry channel-config global-config))

(defn count-downloads
  "Count new downloads in temp directory"
  [temp-dir]
  (count (fs/glob temp-dir "**/*.{mp4,webm,mkv}")))
