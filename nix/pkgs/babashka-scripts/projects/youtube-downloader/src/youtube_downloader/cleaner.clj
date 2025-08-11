(ns youtube-downloader.cleaner
  "File management and cleanup operations"
  (:require
    [babashka.fs :as fs]
    [clojure.string :as str]
    [common.fs :as cfs]
    [common.process :as proc]))


(defn move-downloads
  "Move completed downloads from temp to media directory"
  [temp-dir media-dir & {:keys [dry-run verbose]
                         :or {dry-run false verbose false}}]

  (when verbose
    (println "\nMoving completed downloads..."))

  (let [video-files (fs/glob temp-dir "**/*.{mp4,webm,mkv,m4a}")]
    (if (empty? video-files)
      (when verbose (println "  No downloads to move"))
      (do
        (when verbose
          (println (format "  Found %d files to move" (count video-files))))

        ;; Ensure media directory exists
        (when-not dry-run
          (fs/create-dirs media-dir))

        ;; Use rsync for atomic move with progress
        (let [rsync-cmd ["rsync" "-ahv" "--remove-source-files"
                         (str temp-dir "/")  ; Source with trailing slash
                         (str media-dir "/")]  ; Destination

              result (if dry-run
                       (do
                         (println "  [DRY RUN] Would execute:" (str/join " " rsync-cmd))
                         {:exit 0})
                       (proc/run-command rsync-cmd :throw? false))]

          (if (zero? (:exit result))
            (when verbose
              (println (format "  ✓ Successfully moved %d files" (count video-files))))
            (do
              (println "  ✗ Failed to move files with rsync")
              (println "  Error:" (:err result)))))))))


(defn clean-incomplete-downloads
  "Remove incomplete download files"
  [media-dir & {:keys [dry-run verbose]
                :or {dry-run false verbose false}}]

  (when verbose
    (println "\nCleaning incomplete downloads..."))

  (let [;; Find various incomplete file types
        part-files (fs/glob media-dir "**/*.part")
        temp-files (fs/glob media-dir "**/*.temp.webm")
        meta-files (fs/glob media-dir "**/*.meta")
        vtt-files (fs/glob media-dir "**/*.en.vtt")
        fragment-files (fs/glob media-dir "**/f[0-9]*.webm")

        all-incomplete (concat part-files temp-files meta-files vtt-files fragment-files)]

    (if (empty? all-incomplete)
      (when verbose (println "  No incomplete files found"))
      (do
        (when verbose
          (println (format "  Found %d incomplete files:" (count all-incomplete)))
          (doseq [f all-incomplete]
            (println (format "    %s" f))))

        (if dry-run
          (println "  [DRY RUN] Would remove incomplete files")
          (doseq [f all-incomplete]
            (try
              (fs/delete f)
              (when verbose
                (println (format "  ✓ Removed: %s" f)))
              (catch Exception e
                (println (format "  ✗ Failed to remove %s: %s" f (.getMessage e)))))))))))


(defn clean-empty-directories
  "Remove empty directories"
  [& dirs]
  (println "  Skipping empty directory cleanup (simplified for now)"))


(defn count-total-videos
  "Count total videos in media directory"
  [media-dir]
  (count (fs/glob media-dir "**/*.{mp4,webm,mkv}")))


(defn get-directory-size
  "Get directory size in human readable format"
  [dir]
  (try
    (let [result (proc/run-command ["du" "-sh" dir] :throw? false)]
      (if (zero? (:exit result))
        (first (str/split (:out result) #"\s+"))
        "unknown"))
    (catch Exception _
      "unknown")))


(defn cleanup-old-logs
  "Clean up old log files and temporary data"
  [data-dir & {:keys [dry-run verbose days-old]
               :or {dry-run false verbose false days-old 7}}]

  (when verbose
    (println (format "\nCleaning logs older than %d days..." days-old)))

  (let [log-files (fs/glob data-dir "*.log")
        old-threshold (- (System/currentTimeMillis) (* days-old 24 60 60 1000))]

    (doseq [log-file log-files]
      (when (< (fs/file-time->millis (fs/last-modified-time log-file)) old-threshold)
        (if dry-run
          (println (format "  [DRY RUN] Would remove old log: %s" log-file))
          (try
            (fs/delete log-file)
            (when verbose
              (println (format "  ✓ Removed old log: %s" log-file)))
            (catch Exception e
              (println (format "  ✗ Failed to remove log %s: %s"
                               log-file (.getMessage e))))))))))


(defn maintenance-cleanup
  "Perform comprehensive cleanup and maintenance"
  [config]
  (let [{:keys [temp-dir media-dir data-dir dry-run verbose]} config]

    (when verbose
      (println "\n=== Starting maintenance cleanup ==="))

    ;; Move completed downloads
    (move-downloads temp-dir media-dir :dry-run dry-run :verbose verbose)

    ;; Clean incomplete downloads
    (clean-incomplete-downloads media-dir :dry-run dry-run :verbose verbose)

    ;; Clean empty directories
    (when-not dry-run
      (clean-empty-directories temp-dir media-dir))

    ;; Clean old logs
    (cleanup-old-logs data-dir :dry-run dry-run :verbose verbose)

    ;; Report final stats
    (when verbose
      (let [total-videos (count-total-videos media-dir)
            media-size (get-directory-size media-dir)]
        (println (format "\n=== Final stats ==="))
        (println (format "Total videos: %d" total-videos))
        (println (format "Media directory size: %s" media-size))))))


(defn quick-cleanup
  "Quick cleanup for post-download maintenance"
  [config]
  (let [{:keys [temp-dir media-dir verbose]} config]
    (move-downloads temp-dir media-dir :verbose verbose)
    (clean-empty-directories temp-dir media-dir)))
