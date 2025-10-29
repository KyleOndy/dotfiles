(ns youtube-downloader.observability
  "Observability metrics and logging helpers for YouTube downloader"
  (:require
    [common.logging :as log]
    [common.metrics :as m]))


;; ============================================================================
;; Metrics Definitions
;; ============================================================================

(def downloads-total
  "Total number of download attempts"
  (m/counter "yt_downloads_total"
             "Total number of channel download attempts"))


(def videos-processed-total
  "Total number of videos processed"
  (m/counter "yt_videos_processed_total"
             "Total number of individual videos processed"))


(def errors-total
  "Total number of errors by type"
  (m/counter "yt_errors_total"
             "Total number of errors encountered"))


(def channel-duration-seconds
  "Time spent processing each channel"
  (m/histogram "yt_channel_duration_seconds"
               "Duration of channel processing in seconds"
               [1 5 10 30 60 120 300 600]))


(def session-duration-seconds
  "Total session duration"
  (m/histogram "yt_session_duration_seconds"
               "Duration of entire download session in seconds"
               [60 300 600 1200 1800 3600]))


(def skip-list-size
  "Current size of skip list"
  (m/gauge "yt_skip_list_size"
           "Number of videos in skip list"))


(def last-run-timestamp
  "Timestamp of last successful run"
  (m/gauge "yt_last_run_timestamp"
           "Unix timestamp of last successful run"))


(def retry-attempts-total
  "Total number of retry attempts"
  (m/counter "yt_retry_attempts_total"
             "Total number of retry attempts"))


(def temp-files-count
  "Number of files in temp directory"
  (m/gauge "yt_temp_files_count"
           "Number of files currently in temp directory"))


;; ============================================================================
;; Convenience Functions
;; ============================================================================

(defn record-download-success
  "Record a successful download"
  [channel]
  (m/inc-counter downloads-total {:status "success" :channel channel}))


(defn record-download-failure
  "Record a failed download"
  [channel error-type]
  (m/inc-counter downloads-total {:status "failed" :channel channel})
  (m/inc-counter errors-total {:type (name error-type) :channel channel}))


(defn record-error
  "Record an error"
  [error-type channel]
  (m/inc-counter errors-total {:type (name error-type) :channel channel}))


(defn record-retry
  "Record a retry attempt"
  [channel reason]
  (m/inc-counter retry-attempts-total {:channel channel :reason (name reason)}))


(defn record-videos-processed
  "Record the number of videos processed"
  [count]
  (m/inc-counter videos-processed-total {} count))


(defn record-channel-duration
  "Record the duration of processing a channel"
  [channel duration-seconds]
  (m/observe-histogram channel-duration-seconds {:channel channel} duration-seconds))


(defn record-session-duration
  "Record the duration of the entire session"
  [duration-seconds]
  (m/observe-histogram session-duration-seconds {} duration-seconds))


(defn update-skip-list-size
  "Update the skip list size gauge"
  [size]
  (m/set-gauge skip-list-size {} size))


(defn update-temp-files-count
  "Update the temp files count gauge"
  [count]
  (m/set-gauge temp-files-count {} count))


(defn update-last-run
  "Update the last run timestamp to now"
  []
  (m/set-gauge last-run-timestamp {} (double (/ (System/currentTimeMillis) 1000))))


;; ============================================================================
;; Logging Helpers
;; ============================================================================

(defn log-session-start
  "Log the start of a download session"
  [config]
  (log/info "Starting download session"
            {:channels (count (:channels config))
             :media_dir (:media-dir config)
             :dry_run (:dry-run config false)}))


(defn log-session-end
  "Log the end of a download session"
  [results]
  (let [successful (count (filter #(zero? (:exit %)) results))
        failed (count (filter #(not (zero? (:exit %))) results))]
    (log/info "Download session completed"
              {:total (count results)
               :successful successful
               :failed failed})))


(defn log-channel-start
  "Log the start of channel processing"
  [channel-config]
  (log/info "Processing channel"
            {:channel (:name channel-config)
             :max_videos (:max-videos channel-config)
             :download_shorts (:download-shorts channel-config)}))


(defn log-channel-success
  "Log successful channel processing"
  [channel-name duration-seconds]
  (log/info "Channel processing succeeded"
            {:channel channel-name
             :duration_seconds duration-seconds}))


(defn log-channel-failure
  "Log failed channel processing"
  [channel-name error-type error-msg]
  (log/error "Channel processing failed"
             {:channel channel-name
              :error_type (name error-type)
              :error_message error-msg}))


(defn log-retry-attempt
  "Log a retry attempt"
  [channel attempt max-attempts reason]
  (log/warn "Retrying channel processing"
            {:channel channel
             :attempt attempt
             :max_attempts max-attempts
             :reason (name reason)}))


(defn log-error-skip
  "Log that an error is being skipped (non-retryable)"
  [channel error-type video-id]
  (log/warn "Skipping non-retryable error"
            {:channel channel
             :error_type (name error-type)
             :video_id video-id}))
