(ns roku-transcode.core
  (:require
    [roku-transcode.config :as config]
    [roku-transcode.encoders :as enc]
    [roku-transcode.ffmpeg :as ffmpeg]
    [roku-transcode.system :as sys]))


(defn validate-input
  "Validate input parameters and file"
  [{:keys [input-file options] :as ctx}]
  (ffmpeg/validate-input-file input-file)

  ;; Validate quality preset
  (when-not (contains? config/quality-presets (:quality options))
    (throw (ex-info (format "Invalid quality preset '%s'. Valid options: %s"
                            (:quality options)
                            (clojure.string/join ", " (map name (keys config/quality-presets))))
                    {:quality (:quality options)})))

  ;; Check for conflicting options
  (when (and (:force-gpu options) (:force-cpu options))
    (throw (ex-info "Cannot specify both --gpu and --cpu options" options)))

  ctx)


(defn detect-system-capabilities
  "Detect system capabilities and add to context"
  [ctx]
  (let [capabilities (sys/detect-system-capabilities)]
    (assoc ctx :capabilities capabilities)))


(defn select-best-encoder
  "Select the best encoder for the system and add to context"
  [{:keys [options capabilities] :as ctx}]
  (let [encoder-info (enc/select-best-encoder options capabilities)]
    (assoc ctx :encoder encoder-info)))


(defn build-ffmpeg-command
  "Build FFmpeg command and add to context"
  [{:keys [input-file options encoder capabilities] :as ctx}]
  (let [output-file (ffmpeg/get-output-filename input-file)
        quality-preset (:quality options)
        drm-devices (:drm-devices capabilities)
        ffmpeg-cmd (ffmpeg/build-ffmpeg-command input-file output-file encoder quality-preset drm-devices)]
    (assoc ctx
           :output-file output-file
           :ffmpeg-command ffmpeg-cmd)))


(defn execute-with-progress
  "Execute FFmpeg with progress reporting"
  [{:keys [input-file output-file options encoder ffmpeg-command] :as ctx}]
  (ffmpeg/check-output-file-exists output-file)

  (let [result (ffmpeg/execute-ffmpeg ffmpeg-command
                                      input-file
                                      output-file
                                      encoder
                                      (:quality options)
                                      (:verbose options))]
    (assoc ctx :result result)))


(defn transcode-pipeline
  "Main transcoding pipeline"
  [input-file options]
  (-> {:input-file input-file :options options}
      validate-input
      detect-system-capabilities
      select-best-encoder
      build-ffmpeg-command
      execute-with-progress))


(defn debug-mode
  "Run debug mode to show system information and test encoders"
  [options]
  (let [capabilities (sys/detect-system-capabilities)]
    (sys/show-system-info capabilities)
    (println)
    (println "=== Testing GPU Encoders ===")
    (doseq [encoder-def config/encoders]
      (let [encoder-name (:name encoder-def)]
        (println (format "Testing %s:" encoder-name))
        (enc/test-encoder encoder-name capabilities true)
        (println)))
    {:debug-complete true}))


(defn show-help
  "Show help information"
  []
  (println "Usage: transcode-roku <input_file> [options]")
  (println)
  (println "Transcode a video file to Roku-compatible format (H.264/AAC in MP4).")
  (println)
  (println "Arguments:")
  (println "  input_file              Path to the input video file")
  (println)
  (println "Options:")
  (println "  -q, --quality <preset>  Quality preset: high (default), medium, or low")
  (println "  -g, --gpu               Force GPU acceleration (auto-detect encoder)")
  (println "  -c, --cpu               Force CPU encoding (libx264)")
  (println "  -e, --encoder <name>    Use specific encoder (e.g., h264_nvenc, h264_vaapi)")
  (println "  -v, --verbose           Show encoder detection process")
  (println "  -d, --debug             Show detailed GPU and encoder diagnostics")
  (println "  -h, --help              Show this help message")
  (println)
  (println "Output:")
  (println "  Creates a new file with '_roku' suffix before the extension.")
  (println "  Example: movie.avi -> movie_roku.mp4")
  (println)
  (println "Quality presets:")
  (doseq [[quality-key quality-val] config/quality-presets]
    (println (format "  %-6s - CRF %s, %s audio (%s)"
                     (name quality-key)
                     (:crf quality-val)
                     (:audio-bitrate quality-val)
                     (:desc quality-val))))
  (println)
  (println "Encoders:")
  (println "  Auto-detection tries: h264_nvenc (NVIDIA) → h264_vaapi (Intel/AMD) →")
  (println "                       h264_amf (AMD) → libx264 (CPU)"))
