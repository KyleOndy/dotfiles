(ns roku-transcode.cli
  (:require
    [clojure.string :as str]
    [clojure.tools.cli :as cli]
    [roku-transcode.config :as config]
    [roku-transcode.core :as core]))


(def cli-options
  [["-q" "--quality QUALITY" "Quality preset: high (default), medium, or low"
    :default :high
    :parse-fn keyword
    :validate [#(contains? config/quality-presets %)
               (str "Must be one of: " (str/join ", " (map name (keys config/quality-presets))))]]

   ["-g" "--gpu" "Force GPU acceleration (auto-detect encoder)"]

   ["-c" "--cpu" "Force CPU encoding (libx264)"]

   ["-e" "--encoder ENCODER" "Use specific encoder (e.g., h264_nvenc, h264_vaapi)"]

   ["-v" "--verbose" "Show encoder detection process"]

   ["-d" "--debug" "Show detailed GPU and encoder diagnostics"]

   ["-h" "--help" "Show this help message"]])


(defn usage
  "Generate usage information"
  [options-summary]
  (->> ["Transcode a video file to Roku-compatible format (H.264/AAC in MP4)."
        ""
        "Usage: transcode-roku <input_file> [options]"
        ""
        "Arguments:"
        "  input_file              Path to the input video file"
        ""
        "Options:"
        options-summary
        ""
        "Output:"
        "  Creates a new file with '_roku' suffix before the extension."
        "  Example: movie.avi -> movie_roku.mp4"
        ""
        "Quality presets:"
        (str/join "\n"
                  (for [[quality-key quality-val] config/quality-presets]
                    (format "  %-6s - CRF %s, %s audio (%s)"
                            (name quality-key)
                            (:crf quality-val)
                            (:audio-bitrate quality-val)
                            (:desc quality-val))))
        ""
        "Encoders:"
        "  Auto-detection tries: h264_nvenc (NVIDIA) → h264_vaapi (Intel/AMD) →"
        "                       h264_amf (AMD) → libx264 (CPU)"]
       (str/join \newline)))


(defn error-msg
  "Generate error message"
  [errors]
  (str "The following errors occurred while parsing your command:\n\n"
       (str/join \newline errors)))


(defn validate-args
  "Validate command line arguments"
  [args]
  (let [{:keys [options arguments errors summary]} (cli/parse-opts args cli-options)]
    (cond
      (:help options) ; help => exit OK with usage summary
      {:exit-message (usage summary) :ok? true}

      errors ; errors => exit with description of errors
      {:exit-message (error-msg errors)}

      (:debug options) ; debug mode with no input file
      (if (empty? arguments)
        {:action :debug :options options}
        {:exit-message "Debug mode should not specify an input file"})

      (= (count arguments) 1) ; normal case - one input file
      {:action :transcode :input-file (first arguments) :options options}

      (= (count arguments) 0) ; no input file
      {:exit-message "No input file specified\n\n" :usage summary}

      :else ; too many arguments
      {:exit-message "Multiple input files specified\n\n" :usage summary})))


(defn exit
  "Exit with status code and message"
  [status msg]
  (println msg)
  (System/exit status))


(defn -main
  "Main CLI entry point"
  [& args]
  (let [{:keys [action input-file options exit-message usage ok?]} (validate-args args)]
    (cond
      exit-message
      (if usage
        (exit (if ok? 0 1) (str exit-message (usage usage)))
        (exit (if ok? 0 1) exit-message))

      (= action :debug)
      (try
        (core/debug-mode options)
        (catch Exception e
          (println "Error:" (.getMessage e))
          (System/exit 1)))

      (= action :transcode)
      (try
        (let [result (core/transcode-pipeline input-file options)]
          (if (get-in result [:result :success])
            (System/exit 0)
            (System/exit 1)))
        (catch Exception e
          (println "Error:" (.getMessage e))
          (when (:verbose options)
            (println "Stack trace:")
            (.printStackTrace e))
          (System/exit 1)))

      :else
      (exit 1 "Unknown action"))))
