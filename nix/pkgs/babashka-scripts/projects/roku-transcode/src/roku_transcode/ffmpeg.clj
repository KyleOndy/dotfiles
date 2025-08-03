(ns roku-transcode.ffmpeg
  (:require
    [babashka.process :as p]
    [clojure.string :as str]
    [roku-transcode.config :as config]))


(defn get-output-filename
  "Generate output filename with _roku suffix"
  [input-file]
  (let [file-path (java.nio.file.Paths/get input-file (make-array String 0))
        name-without-ext (str (.getFileName (.getParent file-path)) "/"
                              (str/replace (.toString (.getFileName file-path))
                                           #"\.[^.]*$" ""))
        parent-dir (str (.getParent file-path))]
    (if parent-dir
      (str parent-dir "/" (str/replace (str (.getFileName file-path)) #"\.[^.]*$" "_roku.mp4"))
      (str (str/replace input-file #"\.[^.]*$" "_roku.mp4")))))


(defn build-encoder-args
  "Build encoder-specific arguments"
  [encoder quality-preset]
  (let [{:keys [crf audio-bitrate]} quality-preset
        encoder-name (:encoder encoder)]
    (cond
      (= encoder-name "libx264")
      ["-c:v" "libx264" "-preset" "slow" "-crf" (str crf)]

      (= encoder-name "h264_nvenc")
      ["-c:v" "h264_nvenc" "-preset" "slow" "-cq" (str crf)]

      (= encoder-name "h264_vaapi")
      ["-c:v" "h264_vaapi" "-rc_mode" "CQP" "-global_quality" (str crf)]

      (= encoder-name "h264_amf")
      ["-c:v" "h264_amf" "-quality" "balanced" "-cq" (str crf)]

      :else
      ["-c:v" encoder-name "-crf" (str crf)])))


(defn build-video-filters
  "Build video filter arguments based on encoder"
  [encoder drm-devices]
  (let [encoder-name (:encoder encoder)]
    (cond
      (= encoder-name "h264_vaapi")
      "format=nv12,hwupload"

      :else
      "format=yuv420p")))


(defn build-vaapi-device-args
  "Build VAAPI device arguments if needed"
  [encoder drm-devices]
  (when (= (:encoder encoder) "h264_vaapi")
    (when-let [device (first (filter #(and (:readable? %) (:writable? %)) drm-devices))]
      ["-vaapi_device" (:path device)])))


(defn build-ffmpeg-command
  "Build complete FFmpeg command"
  [input-file output-file encoder quality-preset drm-devices]
  (let [quality-settings (get config/quality-presets quality-preset)
        base-cmd ["ffmpeg"]
        vaapi-args (build-vaapi-device-args encoder drm-devices)
        input-args ["-i" input-file]
        encoder-args (build-encoder-args encoder quality-settings)
        video-filters (build-video-filters encoder drm-devices)
        common-args ["-profile:v" "high"
                     "-level" "4.0"
                     "-vf" video-filters
                     "-c:a" "aac"
                     "-b:a" (:audio-bitrate quality-settings)
                     "-movflags" "+faststart"
                     "-y"
                     output-file]]

    (vec (concat base-cmd
                 (when vaapi-args vaapi-args)
                 input-args
                 encoder-args
                 common-args))))


(defn execute-ffmpeg
  "Execute FFmpeg command with progress reporting"
  [ffmpeg-cmd input-file output-file encoder quality verbose?]
  (println (format "Transcoding '%s' to Roku format..." input-file))
  (println (format "Encoder: %s" (:encoder encoder)))
  (println (format "Quality: %s (CRF: %s, Audio: %s)"
                   (name quality)
                   (get-in config/quality-presets [quality :crf])
                   (get-in config/quality-presets [quality :audio-bitrate])))
  (println (format "Output: %s" output-file))
  (println)

  (when verbose?
    (println "FFmpeg command:")
    (println (str/join " " ffmpeg-cmd))
    (println))

  (let [process (p/process ffmpeg-cmd {:inherit true})
        result @process
        exit-code (:exit result)]
    (if (= 0 exit-code)
      (do
        (println)
        (println (format "Transcoding complete: %s" output-file))
        {:success true :output-file output-file})
      (do
        (println)
        (println "FFmpeg failed with exit code:" exit-code)
        {:success false :exit-code exit-code}))))


(defn check-output-file-exists
  "Check if output file exists and prompt for overwrite"
  [output-file]
  (when (.exists (java.io.File. output-file))
    (println (format "Warning: Output file '%s' already exists" output-file))
    (print "Overwrite? (y/N) ")
    (flush)
    (let [response (or (read-line) "")
          response (str/lower-case (str/trim response))]
      (when-not (= response "y")
        (println "Aborted")
        (System/exit 0)))))


(defn validate-input-file
  "Validate that input file exists"
  [input-file]
  (when-not (.exists (java.io.File. input-file))
    (throw (ex-info (format "Input file '%s' not found" input-file)
                    {:input-file input-file}))))
