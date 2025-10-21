(ns common.metrics-textfile
  "Helper for writing Prometheus metrics to node_exporter textfile collector"
  (:require
   [clojure.java.io :as io]
   [common.logging :as log]
   [common.metrics :as metrics]))

(defn write-metrics-file
  "Write metrics to a textfile for node_exporter textfile collector.

   The file is written atomically by writing to a temp file first, then renaming.
   This prevents node_exporter from reading partial files.

   Args:
     filepath - Full path to the .prom file to write

   Example:
     (write-metrics-file \"/var/lib/prometheus-node-exporter-text-files/youtube-downloader.prom\")"
  [filepath]
  (try
    (let [metrics-output (metrics/export-metrics)
          temp-file (str filepath ".tmp")
          file (io/file filepath)]

      ;; Ensure parent directory exists
      (when-let [parent (.getParentFile file)]
        (.mkdirs parent))

      ;; Write to temp file
      (spit temp-file metrics-output)

      ;; Atomic rename
      (.renameTo (io/file temp-file) file)

      (log/debug "Metrics written to textfile"
                 {:filepath filepath
                  :size (count metrics-output)})
      true)
    (catch Exception e
      (log/error "Failed to write metrics file"
                 {:filepath filepath
                  :error (.getMessage e)})
      false)))

(defn get-textfile-path
  "Get the textfile path for a given service name.

   Uses TEXTFILE_DIRECTORY env var if set, otherwise defaults to NixOS location.

   Args:
     service-name - Name of the service (e.g., 'youtube-downloader')

   Returns:
     Full path to the .prom file"
  [service-name]
  (let [dir (or (System/getenv "TEXTFILE_DIRECTORY")
                "/var/lib/prometheus-node-exporter-text-files")
        filename (str service-name ".prom")]
    (str dir "/" filename)))

(defn write-service-metrics
  "Convenience function to write metrics for a service.

   Args:
     service-name - Name of the service (e.g., 'youtube-downloader')

   Example:
     (write-service-metrics \"youtube-downloader\")"
  [service-name]
  (write-metrics-file (get-textfile-path service-name)))

(comment
  ;; Example usage
  (require '[common.metrics :as m])

  (def test-counter (m/counter "test_metric" "A test metric"))
  (m/inc-counter test-counter {:label "value"})

  ;; Write to textfile
  (write-service-metrics "my-service")

  ;; Check the output
  (slurp "/var/lib/prometheus-node-exporter-text-files/my-service.prom"))
