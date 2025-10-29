(ns common.logging
  "Structured logging for Babashka scripts with JSON output for Loki/Grafana"
  (:require
    [cheshire.core :as json]
    [clojure.string :as str]))


(def ^:dynamic *log-level*
  "Current minimum log level. Can be overridden via LOG_LEVEL env var"
  (let [env-level (str/upper-case (or (System/getenv "LOG_LEVEL") "INFO"))]
    (case env-level
      "DEBUG" :debug
      "INFO" :info
      "WARN" :warn
      "ERROR" :error
      :info)))


(def ^:dynamic *context*
  "Dynamic context map that will be included in all log entries"
  {})


(def level-priority
  {:debug 0
   :info 1
   :warn 2
   :error 3})


(defn should-log?
  "Check if a message at the given level should be logged"
  [level]
  (>= (get level-priority level 1)
      (get level-priority *log-level* 1)))


(defn format-log-entry
  "Format a log entry as JSON"
  [level message context]
  (let [entry (merge
                {:timestamp (str (java.time.Instant/now))
                 :level (str/upper-case (name level))
                 :message message}
                *context*
                context)]
    (json/generate-string entry)))


(defn log
  "Core logging function - outputs structured JSON to stdout"
  ([level message]
   (log level message {}))
  ([level message context]
   (when (should-log? level)
     (println (format-log-entry level message context)))))


(defn debug
  "Log a debug message"
  ([message] (log :debug message {}))
  ([message context] (log :debug message context)))


(defn info
  "Log an info message"
  ([message] (log :info message {}))
  ([message context] (log :info message context)))


(defn warn
  "Log a warning message"
  ([message] (log :warn message {}))
  ([message context] (log :warn message context)))


(defn error
  "Log an error message"
  ([message] (log :error message {}))
  ([message context] (log :error message context)))


(defn with-context
  "Execute a function with additional logging context"
  [context-map f]
  (binding [*context* (merge *context* context-map)]
    (f)))


(defmacro with-logging-context
  "Add context to all log messages within the body"
  [context-map & body]
  `(binding [*context* (merge *context* ~context-map)]
     ~@body))


(defn log-exception
  "Log an exception with stack trace"
  ([ex] (log-exception ex "Exception occurred" {}))
  ([ex message] (log-exception ex message {}))
  ([ex message context]
   (let [stack-trace (with-out-str (.printStackTrace ex))
         context-with-error (merge context
                                   {:exception (str (.getClass ex))
                                    :exception_message (.getMessage ex)
                                    :stack_trace stack-trace})]
     (log :error message context-with-error))))


(comment
  ;; Example usage
  (info "Starting download session" {:channels 5 :mode "normal"})
  (warn "Retry attempt" {:attempt 2 :channel "@example"})
  (error "Download failed" {:channel "@example" :exit_code 1})

  (with-logging-context {:session_id "abc123"}
    (info "Processing channel" {:channel "@example"})
    (info "Download complete" {:videos 3}))

  (try
    (throw (Exception. "Test error"))
    (catch Exception e
      (log-exception e "Failed to process"))))
