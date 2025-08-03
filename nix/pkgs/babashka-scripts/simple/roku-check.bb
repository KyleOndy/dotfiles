#!/usr/bin/env bb

(ns roku-check
  (:require [babashka.cli :as cli]
            [babashka.process :as p]
            [clojure.string :as str]
            [clojure.java.io :as io]
            [cheshire.core :as json]))

;; Roku supported specifications based on official documentation
(def roku-specs
  {:video-codecs
   {"h264" {:profiles #{"baseline" "main" "high"}
            :max-level 4.2
            :max-resolution [1920 1080]
            :name "H.264/AVC"}
    "hevc" {:profiles #{"main" "main 10"}
            :max-level 5.1
            :max-resolution [3840 2160]
            :name "H.265/HEVC"}
    "vp9"  {:profiles #{0 2}
            :max-resolution [3840 2160]
            :name "VP9"}
    "av1"  {:profiles #{"main"}
            :max-level 5.1
            :max-resolution [3840 2160]
            :name "AV1"}}
   
   :audio-codecs
   #{"aac" "ac3" "eac3" "ac4" "alac" "mp3" "pcm"
     "dts" "flac" "vorbis" "opus" "wma" "mp2"}
   
   :containers
   #{"mp4" "mov" "m4v" "mkv" "webm" "mpegts" "hls"}
   
   :frame-rates #{24 25 30 50 60}
   
   :audio-sample-rates #{32000 44100 48000}
   
   :max-audio-channels 8})

(defn run-ffprobe [file]
  (try
    (let [result (p/shell {:out :string :err :string}
                         "ffprobe" "-v" "quiet" "-print_format" "json"
                         "-show_format" "-show_streams" file)]
      (if (zero? (:exit result))
        (json/parse-string (:out result) true)
        {:error (str "ffprobe failed: " (:err result))}))
    (catch Exception e
      {:error (str "Failed to run ffprobe: " (.getMessage e))})))

(defn extract-codec-info [stream]
  (let [codec-name (str/lower-case (or (:codec_name stream) ""))
        codec-type (:codec_type stream)]
    (case codec-type
      "video" {:type :video
               :codec codec-name
               :profile (str/lower-case (or (:profile stream) ""))
               :level (/ (or (:level stream) 0) 10.0)
               :width (:width stream)
               :height (:height stream)
               :frame-rate (if-let [fr (:r_frame_rate stream)]
                            (let [[n d] (map parse-long (str/split fr #"/"))]
                              (if (and n d (pos? d))
                                (/ n d)
                                0))
                            0)}
      "audio" {:type :audio
               :codec codec-name
               :sample-rate (parse-long (or (:sample_rate stream) "0"))
               :channels (:channels stream)}
      nil)))

(defn get-container-format [format-info]
  (some #(get (:format_name format-info) %)
        ["mp4" "mov" "m4v" "mkv" "webm" "mpegts"]))

(defn check-video-codec [video-info]
  (let [{:keys [codec profile level width height frame-rate]} video-info
        codec-spec (get-in roku-specs [:video-codecs codec])]
    (cond
      (nil? codec-spec)
      {:compatible false
       :reason (str "Video codec '" codec "' is not supported by Roku")}
      
      (and (:profiles codec-spec)
           (not (contains? (:profiles codec-spec) profile)))
      {:compatible false
       :reason (str "Video profile '" profile "' is not supported for " (:name codec-spec))}
      
      (and (:max-level codec-spec)
           (> level (:max-level codec-spec)))
      {:compatible false
       :reason (str "Video level " level " exceeds maximum " (:max-level codec-spec) " for " (:name codec-spec))}
      
      (let [[max-w max-h] (:max-resolution codec-spec)]
        (or (> width max-w) (> height max-h)))
      {:compatible false
       :reason (str "Resolution " width "x" height " exceeds maximum "
                   (str/join "x" (:max-resolution codec-spec)) " for " (:name codec-spec))}
      
      (not (contains? (:frame-rates roku-specs) (int frame-rate)))
      {:compatible false
       :reason (str "Frame rate " frame-rate " fps is not supported")}
      
      :else
      {:compatible true
       :codec (:name codec-spec)
       :profile profile
       :level level
       :resolution (str width "x" height)
       :frame-rate frame-rate})))

(defn check-audio-codec [audio-info]
  (let [{:keys [codec sample-rate channels]} audio-info]
    (cond
      (not (contains? (:audio-codecs roku-specs) codec))
      {:compatible false
       :reason (str "Audio codec '" codec "' is not supported by Roku")}
      
      (not (contains? (:audio-sample-rates roku-specs) sample-rate))
      {:compatible false
       :reason (str "Audio sample rate " sample-rate " Hz is not supported")}
      
      (> channels (:max-audio-channels roku-specs))
      {:compatible false
       :reason (str "Audio with " channels " channels exceeds maximum of "
                   (:max-audio-channels roku-specs))}
      
      :else
      {:compatible true
       :codec codec
       :sample-rate sample-rate
       :channels channels})))

(defn check-container [format-name]
  (let [container (first (filter #(str/includes? (str/lower-case format-name) %)
                                ["mp4" "mov" "m4v" "mkv" "webm" "mpegts"]))]
    (if (contains? (:containers roku-specs) container)
      {:compatible true :format container}
      {:compatible false
       :reason (str "Container format '" format-name "' is not supported by Roku")})))

(defn analyze-file [file detailed?]
  (let [probe-data (run-ffprobe file)]
    (if (:error probe-data)
      {:file file
       :compatible false
       :error (:error probe-data)}
      (let [streams (map extract-codec-info (:streams probe-data))
            video-streams (filter #(= (:type %) :video) streams)
            audio-streams (filter #(= (:type %) :audio) streams)
            container-check (check-container (get-in probe-data [:format :format_name]))
            video-checks (map check-video-codec video-streams)
            audio-checks (map check-audio-codec audio-streams)
            all-compatible? (and (:compatible container-check)
                               (every? :compatible video-checks)
                               (every? :compatible audio-checks))]
        {:file file
         :compatible all-compatible?
         :container container-check
         :video video-checks
         :audio audio-checks}))))

(defn format-result [result detailed?]
  (let [{:keys [file compatible error container video audio]} result]
    (if error
      (str "❌ " file "\n   Error: " error)
      (if detailed?
        (str (if compatible "✅ " "❌ ") file "\n"
             "   Container: " (if (:compatible container)
                               (str (:format container) " ✓")
                               (:reason container)) "\n"
             (when (seq video)
               (str "   Video: "
                    (str/join "\n          "
                             (map #(if (:compatible %)
                                    (str (:codec %) " " (:resolution %) " @ " (:frame-rate %) "fps ✓")
                                    (:reason %))
                                  video)) "\n"))
             (when (seq audio)
               (str "   Audio: "
                    (str/join "\n          "
                             (map #(if (:compatible %)
                                    (str (:codec %) " " (:sample-rate %) "Hz " (:channels %) "ch ✓")
                                    (:reason %))
                                  audio)))))
        (str (if compatible "✅ " "❌ ") file
             (when-not compatible
               (let [reasons (concat
                             (when-not (:compatible container) [(:reason container)])
                             (map :reason (remove :compatible video))
                             (map :reason (remove :compatible audio)))]
                 (str " - " (first reasons)))))))))

(def cli-spec
  {:detailed {:desc "Show detailed analysis"
             :alias :d}
   :help {:desc "Show help"
          :alias :h}})

(defn -main [& args]
  (let [help? (some #{"--help" "-h"} args)
        detailed? (some #{"--detailed" "-d"} args)
        files (remove #(str/starts-with? % "-") args)]

    (cond
      (or help? (empty? files))
      (do
        (println "Roku Media File Compatibility Checker")
        (println "Usage: roku-check.bb [options] <file1> [file2 ...]")
        (println)
        (println "Options:")
        (println "  -d, --detailed    Show detailed analysis")
        (println "  -h, --help        Show this help message")
        (System/exit 0))
      
      :else
      (let [results (doall (map #(analyze-file % detailed?) files))]
        (doseq [result results]
          (println (format-result result detailed?)))
        (when (> (count results) 1)
          (let [compatible-count (count (filter :compatible results))]
            (println)
            (println (str "Summary: " compatible-count "/" (count results) " files compatible"))))
        (System/exit (if (every? :compatible results) 0 1))))))

(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))