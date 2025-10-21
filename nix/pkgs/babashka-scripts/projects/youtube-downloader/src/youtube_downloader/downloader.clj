(ns youtube-downloader.downloader
  "Core downloading functionality using yt-dlp"
  (:require
   [babashka.fs :as fs]
   [clojure.string :as str]
   [common.logging :as log]
   [common.process :as proc]
   [youtube-downloader.anti-bot :as anti-bot]
   [youtube-downloader.config :as config]
   [youtube-downloader.observability :as obs]))

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
        (let [skip-list (->> (slurp skip-file)
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
                             vec)]
          (log/debug "Loaded skip list" {:count (count skip-list) :skip_file skip-file})
          (obs/update-skip-list-size (count skip-list))
          skip-list)
        (catch Exception e
          (log/warn "Could not load skip list" {:error (.getMessage e) :skip_file skip-file})
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
  (let [cmd (build-yt-dlp-command channel-config global-config)
        channel-name (:name channel-config)]
    (loop [attempt 0]
      (log/debug "Starting download attempt"
                 {:channel channel-name
                  :attempt (inc attempt)
                  :max_attempts max-attempts
                  :max_videos (:max-videos channel-config)})

      (let [result (if (:dry-run global-config)
                     (do
                       (log/info "Dry run mode - would execute yt-dlp"
                                 {:channel channel-name
                                  :command (str/join " " (take 10 cmd))})
                       {:exit 0 :out "Dry run" :err ""})
                     (proc/run-command cmd :throw? false :timeout 600000))]

        (cond
          ;; Success
          (zero? (:exit result))
          (do
            (log/info "Channel download succeeded" {:channel channel-name})
            (obs/record-download-success channel-name)
            result)

          ;; Check if we should retry
          (>= attempt (dec max-attempts))
          (let [error-info (parse-download-error (:err result))
                error-type (:type error-info)]
            (log/error "Channel download failed after all retries"
                       {:channel channel-name
                        :error_type (name error-type)
                        :max_attempts max-attempts})
            (obs/record-download-failure channel-name error-type)
            ;; Include error info in the result for summary
            (assoc result
                   :error-type error-type
                   :error-msg (first (str/split-lines (:err result)))))

          ;; Parse error and decide on retry
          :else
          (let [error-info (parse-download-error (:err result))]
            (if (:retry? error-info)
              (do
                (log/warn "Retrying after retryable error"
                          {:channel channel-name
                           :error_type (name (:type error-info))
                           :retry_reason "retryable_error"})
                (obs/record-retry channel-name (:type error-info))
                (when (= :rate-limit (:type error-info))
                  (anti-bot/handle-rate-limit (:err result) attempt))
                (Thread/sleep (anti-bot/exponential-backoff attempt))
                (recur (inc attempt)))
              (do
                ;; Non-retryable error - log and skip
                (when-let [video-id (extract-video-id (:err result))]
                  (log/warn "Adding video to skip list"
                            {:channel channel-name
                             :video_id video-id
                             :error_type (name (:type error-info))})
                  (add-to-skip-list (:data-dir global-config)
                                    video-id
                                    (name (:type error-info))))
                (obs/record-download-failure channel-name (:type error-info))
                (assoc result
                       :error_type (:type error-info)
                       :error-msg (first (str/split-lines (:err result)))))))))))) ; closes assoc, do, if, let error-info, cond, let result, loop, let cmd, defn

(defn download-channel
  "Download videos from a single channel"
  [channel-config global-config]
  (log/info "Processing channel"
            {:channel (:name channel-config)
             :max_videos (:max-videos channel-config)
             :download_shorts (:download-shorts channel-config)})

  ;; Ensure temp directory exists
  (fs/create-dirs (:temp-dir global-config))

  ;; Download with retry logic - yt-dlp handles sleep between actual downloads
  (download-with-retry channel-config global-config))

(defn count-downloads
  "Count new downloads in temp directory"
  [temp-dir]
  (count (fs/glob temp-dir "**/*.{mp4,webm,mkv}")))
