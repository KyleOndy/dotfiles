(ns common.process
  "Common process execution utilities for babashka scripts"
  (:require
    [babashka.process :as p]
    [clojure.string :as str]))


(defn run-command
  "Run a command and return the result"
  [cmd & {:keys [dir env stdin throw? timeout]
          :or {throw? true timeout 30000}}]
  (let [opts (cond-> {:out :string :err :string}
               dir (assoc :dir dir)
               env (assoc :env env)
               stdin (assoc :in stdin)
               timeout (assoc :timeout timeout))]
    (try
      (let [result (apply p/shell opts cmd)]
        (if (and throw? (not (zero? (:exit result))))
          (throw (ex-info (str "Command failed: " (str/join " " cmd))
                          {:exit-code (:exit result)
                           :stderr (:err result)
                           :stdout (:out result)}))
          result))
      (catch Exception e
        (if throw?
          (throw e)
          {:exit 1 :err (.getMessage e) :out ""})))))


(defn command-exists?
  "Check if a command exists by testing its functionality"
  [cmd]
  (try
    ;; Test with --version flag which most tools support
    (let [result (run-command [cmd "--version"] :throw? false :timeout 3000)]
      (zero? (:exit result)))
    (catch Exception _
      ;; If --version fails, try --help as fallback
      (try
        (let [result (run-command [cmd "--help"] :throw? false :timeout 3000)]
          (zero? (:exit result)))
        (catch Exception _
          false)))))


(defn run-with-retry
  "Run a command with retry logic"
  [cmd & {:keys [max-attempts delay throw?]
          :or {max-attempts 3 delay 1000 throw? true}}]
  (loop [attempt 1]
    (let [result (run-command cmd :throw? false)]
      (if (or (zero? (:exit result)) (>= attempt max-attempts))
        (if (and throw? (not (zero? (:exit result))))
          (throw (ex-info "Command failed after retries"
                          {:attempts attempt
                           :exit-code (:exit result)
                           :stderr (:err result)}))
          result)
        (do
          (Thread/sleep delay)
          (recur (inc attempt)))))))


(defn run-async
  "Run a command asynchronously and return a future"
  [cmd & {:keys [dir env]}]
  (let [opts (cond-> {:out :string :err :string}
               dir (assoc :dir dir)
               env (assoc :env env))]
    (future (apply p/shell opts cmd))))


(defn kill-process
  "Kill a process by PID"
  [pid & {:keys [signal] :or {signal "TERM"}}]
  (run-command ["kill" (str "-" signal) (str pid)] :throw? false))
