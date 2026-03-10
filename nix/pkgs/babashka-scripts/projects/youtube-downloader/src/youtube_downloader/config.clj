(ns youtube-downloader.config
  "Configuration management for YouTube downloader"
  (:require
    [babashka.fs :as fs]
    [cheshire.core :as json]
    [clojure.string :as str]))


(def default-config
  "Conservative defaults to minimize bot detection"
  {:max-videos-default 5 ; Very conservative - only 5 most recent
   :max-videos-initial 30 ; First run only - populate archive
   :download-shorts false ; Don't download shorts by default
   :sleep-between-channels 60
   :sleep-between-videos {:min 5 :max 30}})


(defn sanitize-channel-name
  "Create a safe filename from channel name using hash + truncated name"
  [channel-name]
  (let [hash-str (-> channel-name
                     hash
                     Math/abs
                     str)
        ;; Ensure we always have 8 chars by padding with zeros if needed
        hash (if (>= (count hash-str) 8)
               (subs hash-str 0 8)
               (format "%08d" (Integer/parseInt hash-str)))
        safe-name (-> channel-name
                      (str/replace #"[^a-zA-Z0-9\-_]" "")
                      str/lower-case
                      (#(if (> (count %) 20) (subs % 0 20) %)))]
    (str hash "-" safe-name)))


(defn channel-archive-path
  "Get the archive file path for a specific channel"
  [data-dir channel-name]
  (str data-dir "/youtube-dl-seen-" (sanitize-channel-name channel-name) ".conf"))


(defn migrate-shared-archive
  "Migrate from shared archive to per-channel archives.
   Does NOT copy the shared archive to each channel - that would bloat every
   channel's seen file with all other channels' video IDs. Instead, channels
   start fresh and rebuild their archives via max-videos-initial."
  [data-dir _channels]
  (let [old-archive (str data-dir "/youtube-dl-seen.conf")
        migration-marker (str old-archive ".migrated")]
    (when (and (fs/exists? old-archive)
               (not (fs/exists? migration-marker)))
      (println "Migrating shared archive: retiring old shared file.")
      (println "  Each channel will rebuild its archive on next run.")
      (fs/move old-archive migration-marker)
      (println "Migration completed"))))


(defn cleanup-bloated-archives
  "One-time cleanup of per-channel archives that were bloated by the old
   migration copying the entire shared archive into every channel's file.
   Detects this by the presence of .migrated marker (old migration ran)
   without .archives-cleaned marker (this cleanup already ran)."
  [data-dir]
  (let [migrated-marker (str data-dir "/youtube-dl-seen.conf.migrated")
        cleaned-marker (str data-dir "/.archives-cleaned")]
    (when (and (fs/exists? migrated-marker)
               (not (fs/exists? cleaned-marker)))
      (let [archive-files (fs/glob data-dir "youtube-dl-seen-*.conf")]
        (when (seq archive-files)
          (println (str "Cleaning up " (count archive-files) " bloated per-channel archives..."))
          (doseq [f archive-files]
            (println (str "  Removing " (fs/file-name f)))
            (fs/delete f))
          (println "Each channel will rebuild its archive on next download.")))
      (spit cleaned-marker (str (java.time.Instant/now) "\n")))))


(defn archive-exists?
  "Check if the download archive exists for a specific channel"
  [data-dir channel-name]
  (fs/exists? (channel-archive-path data-dir channel-name)))


(defn parse-channel
  "Parse a channel configuration, applying defaults"
  [ch defaults data-dir]
  (let [channel-name (if (string? ch) ch (:name ch))
        archive-exists? (archive-exists? data-dir channel-name)
        base-max (if archive-exists?
                   (:max-videos-default defaults)
                   (:max-videos-initial defaults))]
    (if (string? ch)
      {:name ch
       :download-shorts (:download-shorts defaults)
       :max-videos base-max}
      {:name (:name ch)
       :download-shorts (get ch :download_shorts (:download-shorts defaults))
       :max-videos (get ch :max_videos base-max)})))


(defn from-env
  "Load configuration from environment variables"
  []
  (let [media-dir (or (System/getenv "YT_MEDIA_DIR")
                      "/var/lib/youtube-downloader")
        data-dir (or (System/getenv "YT_DATA_DIR")
                     "/var/lib/youtube-downloader")
        temp-dir (or (System/getenv "YT_TEMP_DIR")
                     (str data-dir "/temp"))

        ;; Parse channels from JSON
        channels-json (System/getenv "YT_CHANNELS")
        channels-raw (when channels-json
                       (json/parse-string channels-json true))

        ;; Get defaults from environment
        download-shorts-default (= "true" (System/getenv "YT_DOWNLOAD_SHORTS_DEFAULT"))
        max-videos-default (if-let [v (System/getenv "YT_MAX_VIDEOS_DEFAULT")]
                             (Integer/parseInt v)
                             (:max-videos-default default-config))
        max-videos-initial (if-let [v (System/getenv "YT_MAX_VIDEOS_INITIAL")]
                             (Integer/parseInt v)
                             (:max-videos-initial default-config))

        ;; Build config with defaults
        config-defaults (merge default-config
                               {:download-shorts download-shorts-default
                                :max-videos-default max-videos-default
                                :max-videos-initial max-videos-initial})

        ;; Parse channels with defaults applied (now per-channel)
        channels (map #(parse-channel % config-defaults data-dir) channels-raw)]

    ;; Run migration before returning config
    (migrate-shared-archive data-dir channels)
    (cleanup-bloated-archives data-dir)

    {:media-dir media-dir
     :data-dir data-dir
     :temp-dir temp-dir
     :channels channels
     :delete-grace-period (or (System/getenv "YT_DELETE_GRACE_PERIOD") "36 hours")
     :sleep-between-channels (if-let [v (System/getenv "YT_SLEEP_BETWEEN_CHANNELS")]
                               (Integer/parseInt v)
                               (:sleep-between-channels default-config))
     :sleep-between-videos (:sleep-between-videos default-config)
     :dry-run (= "true" (System/getenv "YT_DRY_RUN"))}))


(defn validate-config
  "Validate configuration and return errors if any"
  [config]
  (cond
    (empty? (:channels config))
    {:error "No channels configured"}

    (not (fs/exists? (:data-dir config)))
    {:error (str "Data directory does not exist: " (:data-dir config))}

    :else nil))
