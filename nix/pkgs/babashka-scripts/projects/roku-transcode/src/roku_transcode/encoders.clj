(ns roku-transcode.encoders
  (:require
    [babashka.process :as p]
    [clojure.string :as str]
    [roku-transcode.config :as config]
    [roku-transcode.system :as sys]))


(defn get-available-encoders
  "Get list of available H.264 encoders from FFmpeg"
  []
  (let [{:keys [out]} (sys/run-cmd "ffmpeg" "-hide_banner" "-encoders")]
    (->> (str/split-lines out)
         (filter #(re-find #"^\s*V\S*\s+h264" %))
         (map #(second (re-find #"h264\w*" %)))
         (remove nil?))))


(defn encoder-available?
  "Check if a specific encoder is available in FFmpeg"
  [encoder-name]
  (let [available (get-available-encoders)]
    (some #(= encoder-name %) available)))


(defn test-nvenc-encoder
  "Test NVENC encoder functionality"
  [debug?]
  (when debug? (println "    Testing NVENC encoding..."))
  (let [{:keys [exit err]} (sys/run-cmd "ffmpeg" "-hide_banner" "-loglevel" "error"
                                        "-f" "lavfi" "-i" "testsrc2=duration=1:size=320x240:rate=30"
                                        "-c:v" "h264_nvenc" "-f" "null" "-")]
    (when debug?
      (if (= 0 exit)
        (println "      ✓ NVENC encoding test successful")
        (println "      ✗ NVENC encoding failed:" (str/trim err))))
    (= 0 exit)))


(defn test-vaapi-encoder
  "Test VAAPI encoder functionality"
  [debug? drm-devices]
  (when debug? (println "    Testing VAAPI encoding..."))
  (loop [devices drm-devices]
    (if (empty? devices)
      false
      (let [device (first devices)
            device-path (:path device)]
        (when debug? (println (format "      Testing with device: %s" device-path)))
        (if (and (:readable? device) (:writable? device))
          (let [{:keys [exit err]} (sys/run-cmd "ffmpeg" "-hide_banner" "-loglevel" "error"
                                                "-vaapi_device" device-path
                                                "-f" "lavfi" "-i" "testsrc2=duration=1:size=320x240:rate=30"
                                                "-vf" "format=nv12,hwupload"
                                                "-c:v" "h264_vaapi" "-f" "null" "-")]
            (when debug?
              (if (= 0 exit)
                (println "      ✓ VAAPI encoding test successful")
                (println "      ✗ VAAPI encoding failed:" (str/trim err))))
            (if (= 0 exit)
              true
              (recur (rest devices))))
          (do
            (when debug? (println "      ✗ No permission to access device"))
            (recur (rest devices))))))))


(defn test-amf-encoder
  "Test AMF encoder functionality"
  [debug?]
  (when debug? (println "    Testing AMF encoding..."))
  (let [{:keys [exit err]} (sys/run-cmd "ffmpeg" "-hide_banner" "-loglevel" "error"
                                        "-f" "lavfi" "-i" "testsrc2=duration=1:size=320x240:rate=30"
                                        "-c:v" "h264_amf" "-f" "null" "-")]
    (when debug?
      (if (= 0 exit)
        (println "      ✓ AMF encoding test successful")
        (println "      ✗ AMF encoding failed:" (str/trim err))))
    (= 0 exit)))


(defn test-cpu-encoder
  "Test CPU encoder (always works)"
  [debug?]
  (when debug? (println "    Testing CPU encoding..."))
  (let [{:keys [exit]} (sys/run-cmd "ffmpeg" "-hide_banner" "-loglevel" "error"
                                    "-f" "lavfi" "-i" "testsrc2=duration=1:size=320x240:rate=30"
                                    "-c:v" "libx264" "-f" "null" "-")]
    (when debug?
      (if (= 0 exit)
        (println "      ✓ CPU encoding test successful")
        (println "      ✗ CPU encoding failed")))
    (= 0 exit)))


(defn test-encoder
  "Test if an encoder works with current system"
  [encoder-name capabilities debug?]
  (when debug? (println (format "Testing %s:" encoder-name)))

  (cond
    (= encoder-name "h264_nvenc")
    (test-nvenc-encoder debug?)

    (= encoder-name "h264_vaapi")
    (test-vaapi-encoder debug? (:drm-devices capabilities))

    (= encoder-name "h264_amf")
    (test-amf-encoder debug?)

    (= encoder-name "libx264")
    (test-cpu-encoder debug?)

    :else
    (do
      (when debug? (println (format "    Testing generic encoder: %s" encoder-name)))
      (let [{:keys [exit]} (sys/run-cmd "ffmpeg" "-hide_banner" "-loglevel" "error"
                                        "-f" "lavfi" "-i" "testsrc2=duration=1:size=320x240:rate=30"
                                        "-c:v" encoder-name "-f" "null" "-")]
        (= 0 exit)))))


(defn select-best-encoder
  "Select the best available encoder based on options and system capabilities"
  [options capabilities]
  (let [{:keys [force-gpu force-cpu encoder verbose debug]} options]

    (when debug (sys/show-system-info capabilities))

    (cond
      ;; Specific encoder requested
      encoder
      (do
        (when verbose (println (format "Testing specific encoder: %s" encoder)))
        (if (and (encoder-available? encoder)
                 (test-encoder encoder capabilities debug))
          {:encoder encoder :type :specified}
          (throw (ex-info (format "Specified encoder '%s' not available" encoder)
                          {:encoder encoder}))))

      ;; Force CPU
      force-cpu
      {:encoder "libx264" :type :cpu}

      ;; Try GPU encoders first, then CPU
      :else
      (let [gpu-encoders (if force-gpu
                           ["h264_nvenc" "h264_vaapi" "h264_amf"]
                           ["h264_nvenc" "h264_vaapi" "h264_amf"])]
        (when debug (println "=== Testing GPU Encoders ==="))
        (when verbose (println "Detecting available encoders..."))

        (loop [encoders-to-try gpu-encoders]
          (if (empty? encoders-to-try)
            (if force-gpu
              (throw (ex-info "No GPU encoder available" {:force-gpu true}))
              (do
                (when verbose (println "  Using CPU encoder (libx264)"))
                {:encoder "libx264" :type :cpu}))
            (let [current-encoder (first encoders-to-try)]
              (if (and (encoder-available? current-encoder)
                       (test-encoder current-encoder capabilities debug))
                (do
                  (when verbose (println (format "  ✓ %s is available" current-encoder)))
                  {:encoder current-encoder :type :gpu})
                (do
                  (when verbose (println (format "  ✗ %s not available" current-encoder)))
                  (recur (rest encoders-to-try)))))))))))


(defn show-encoder-info
  "Display information about available encoders"
  []
  (println "Available H.264 encoders:")
  (let [available (get-available-encoders)]
    (doseq [encoder-def config/encoders]
      (let [encoder-name (:name encoder-def)
            available? (some #(= encoder-name %) available)]
        (println (format "  %s %s - %s"
                         (if available? "✓" "✗")
                         encoder-name
                         (:desc encoder-def)))))))
