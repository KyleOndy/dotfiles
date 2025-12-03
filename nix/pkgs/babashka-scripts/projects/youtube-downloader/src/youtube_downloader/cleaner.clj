(ns youtube-downloader.cleaner
  "File management and cleanup operations"
  (:require
    [babashka.fs :as fs]
    [clojure.string :as str]
    [common.process :as proc]))


(defn move-downloads
  "Move completed downloads from temp to media directory"
  [temp-dir media-dir & {:keys [dry-run]
                         :or {dry-run false}}]

  (let [video-files (fs/glob temp-dir "**/*.{mp4,webm,mkv,m4a}")]
    (if (empty? video-files)
      (println "Moving downloads: 0 files found")
      (do
        (println (format "Moving downloads: %d files found" (count video-files)))

        ;; Ensure media directory exists
        (when-not dry-run
          (fs/create-dirs media-dir))

        ;; Use rsync for atomic move with progress
        (let [rsync-cmd ["rsync" "-ahv" "--remove-source-files"
                         (str temp-dir "/") ; Source with trailing slash
                         (str media-dir "/")] ; Destination

              result (if dry-run
                       (do
                         (println "  [DRY RUN] Would execute:" (str/join " " rsync-cmd))
                         {:exit 0})
                       (proc/run-command rsync-cmd :throw? false))]

          (if (zero? (:exit result))
            (println (format "  ✓ Successfully moved %d files" (count video-files)))
            (do
              (println "  ✗ Failed to move files with rsync")
              (println "  Error:" (:err result)))))))))


(defn clean-incomplete-downloads
  "Remove incomplete download files"
  [media-dir & {:keys [dry-run]
                :or {dry-run false}}]

  (let [;; Find various incomplete file types
        part-files (fs/glob media-dir "**/*.part")
        temp-files (fs/glob media-dir "**/*.temp.webm")
        meta-files (fs/glob media-dir "**/*.meta")
        vtt-files (fs/glob media-dir "**/*.en.vtt")
        fragment-files (fs/glob media-dir "**/f[0-9]*.webm")

        all-incomplete (concat part-files temp-files meta-files vtt-files fragment-files)]

    (if (empty? all-incomplete)
      (println "Cleaning incomplete downloads: 0 files found")
      (do
        (println (format "Cleaning incomplete downloads: %d files found" (count all-incomplete)))

        (if dry-run
          (println "  [DRY RUN] Would remove incomplete files")
          (let [removed (atom 0)
                failed (atom 0)]
            (doseq [f all-incomplete]
              (try
                (fs/delete f)
                (swap! removed inc)
                (catch Exception _
                  (swap! failed inc))))
            (println (format "  ✓ Removed %d files, %d failed" @removed @failed))))))))


(defn clean-empty-directories
  "Remove empty directories from temp directory (bottom-up, iteratively)"
  [temp-dir & {:keys [dry-run]
               :or {dry-run false}}]
  (let [find-empty-dirs (fn []
                          (->> (fs/glob temp-dir "**")
                               (filter fs/directory?)
                               (filter #(not= (fs/normalize %) (fs/normalize temp-dir)))
                               (sort-by #(- (count (fs/components %))))
                               (filter #(empty? (fs/list-dir %)))))
        total-removed (atom 0)
        total-failed (atom 0)]

    (if dry-run
      ;; Dry run: just count what would be removed
      (let [empty-dirs (find-empty-dirs)]
        (if (empty? empty-dirs)
          (println "Cleaning empty directories: 0 found")
          (do
            (println (format "Cleaning empty directories: %d found" (count empty-dirs)))
            (println "  [DRY RUN] Would remove empty directories"))))

      ;; Actual cleanup: loop until no more empty dirs
      (loop [empty-dirs (find-empty-dirs)
             iteration 1]
        (if (empty? empty-dirs)
          (when (> @total-removed 0)
            (println (format "  ✓ Removed %d directories, %d failed" @total-removed @total-failed)))
          (do
            (when (= iteration 1)
              (println (format "Cleaning empty directories: %d found" (count empty-dirs))))
            (doseq [d empty-dirs]
              (try
                (fs/delete d)
                (swap! total-removed inc)
                (catch Exception _
                  (swap! total-failed inc))))
            ;; Check again for newly-empty parent directories
            (recur (find-empty-dirs) (inc iteration))))))))


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
  [data-dir & {:keys [dry-run days-old]
               :or {dry-run false days-old 7}}]

  (let [log-files (fs/glob data-dir "*.log")
        old-threshold (- (System/currentTimeMillis) (* days-old 24 60 60 1000))
        old-logs (filter #(< (fs/file-time->millis (fs/last-modified-time %)) old-threshold)
                         log-files)]

    (if (empty? old-logs)
      (println (format "Cleaning logs older than %d days: 0 files found" days-old))
      (do
        (println (format "Cleaning logs older than %d days: %d files found" days-old (count old-logs)))
        (if dry-run
          (println "  [DRY RUN] Would remove old logs")
          (let [removed (atom 0)
                failed (atom 0)]
            (doseq [log-file old-logs]
              (try
                (fs/delete log-file)
                (swap! removed inc)
                (catch Exception _
                  (swap! failed inc))))
            (println (format "  ✓ Removed %d logs, %d failed" @removed @failed))))))))


(defn maintenance-cleanup
  "Perform comprehensive cleanup and maintenance"
  [config]
  (let [{:keys [temp-dir media-dir data-dir dry-run]} config]

    (println "\n=== Starting maintenance cleanup ===")

    ;; Move completed downloads
    (move-downloads temp-dir media-dir :dry-run dry-run)

    ;; Clean incomplete downloads
    (clean-incomplete-downloads media-dir :dry-run dry-run)

    ;; Clean empty directories
    (clean-empty-directories temp-dir :dry-run dry-run)

    ;; Clean old logs
    (cleanup-old-logs data-dir :dry-run dry-run)

    ;; Report final stats
    (let [total-videos (count-total-videos media-dir)
          media-size (get-directory-size media-dir)]
      (println (format "\nFinal stats: %d videos | %s total size"
                       total-videos media-size)))))


(defn quick-cleanup
  "Quick cleanup for post-download maintenance"
  [config]
  (let [{:keys [temp-dir media-dir]} config]
    (move-downloads temp-dir media-dir)
    (clean-empty-directories temp-dir)))
