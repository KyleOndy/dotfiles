(ns common.fs
  "Common filesystem utilities for babashka scripts"
  (:require
    [babashka.fs :as fs]
    [clojure.java.io :as io]
    [clojure.string :as str]))


(defn ensure-directory
  "Ensure a directory exists, creating it if necessary"
  [path]
  (fs/create-dirs path)
  path)


(defn safe-delete
  "Safely delete a file or directory with confirmation"
  [path & {:keys [force?] :or {force? false}}]
  (when (fs/exists? path)
    (if (or force?
            (do (print (str "Delete " path "? (y/N): "))
                (flush)
                (= "y" (str/lower-case (str/trim (read-line))))))
      (fs/delete-tree path)
      (println "Skipped deletion of" path))))


(defn find-files
  "Find files matching a pattern (glob or regex)"
  [root pattern & {:keys [type] :or {type :glob}}]
  (case type
    :glob (fs/glob root pattern)
    :regex (filter #(re-matches pattern (str %))
                   (fs/walk-file-tree root))
    (throw (ex-info "Invalid pattern type" {:type type}))))


(defn file-extension
  "Get the file extension without the dot"
  [path]
  (let [name (fs/file-name path)]
    (when-let [dot-idx (str/last-index-of name ".")]
      (subs name (inc dot-idx)))))


(defn file-size-human
  "Get human-readable file size"
  [path]
  (let [size (fs/size path)
        units ["B" "KB" "MB" "GB" "TB"]]
    (loop [s (double size)
           u units]
      (if (or (< s 1024) (= 1 (count u)))
        (format "%.1f %s" s (first u))
        (recur (/ s 1024) (rest u))))))


(defn backup-file
  "Create a backup of a file with timestamp"
  [path]
  (let [timestamp (.format (java.time.LocalDateTime/now)
                           (java.time.format.DateTimeFormatter/ofPattern "yyyyMMdd-HHmmss"))
        backup-path (str path ".bak." timestamp)]
    (fs/copy path backup-path)
    backup-path))


(defn temp-file
  "Create a temporary file with optional prefix and suffix"
  [& {:keys [prefix suffix] :or {prefix "bb-script" suffix ".tmp"}}]
  (fs/create-temp-file {:prefix prefix :suffix suffix}))
