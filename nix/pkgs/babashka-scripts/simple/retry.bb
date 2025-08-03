#!/usr/bin/env bb

(ns retry
  "Advanced retry script with backoff strategies, jitter, and smart exit code handling"
  (:require [babashka.cli :as cli]
            [babashka.process :as p]
            [clojure.string :as str]))

;; Default configuration
(def default-config
  {:max-attempts 5
   :backoff-strategy "exponential"
   :base-delay 1000
   :max-delay 30000
   :jitter "equal"
   :non-retryable-codes #{126 127}
   :verbose false
   :dry-run false})

;; CLI specification for babashka.cli
(def cli-spec
  {:max-attempts {:ref "<num>"
                  :desc "Maximum number of retry attempts"}
   :backoff-strategy {:ref "<strategy>"
                      :desc "Backoff strategy: linear, exponential, fibonacci, fixed"}
   :base-delay {:ref "<ms>"
                :desc "Base delay in milliseconds"}
   :max-delay {:ref "<ms>"
               :desc "Maximum delay in milliseconds"}
   :jitter {:ref "<type>"
            :desc "Jitter type: full, equal, decorrelated, none"}
   :timeout-per-attempt {:ref "<ms>"
                         :desc "Timeout per attempt in milliseconds"}
   :total-timeout {:ref "<ms>"
                   :desc "Total timeout for all attempts in milliseconds"}
   :non-retryable-codes {:ref "<codes>"
                         :desc "Comma-separated list of exit codes that should not be retried"}
   :verbose {:desc "Enable verbose logging"}
   :dry-run {:desc "Show what would be executed without running commands"}
   :help {:desc "Show help"}})

(defn calculate-fibonacci-delay
  "Calculate fibonacci-based delay for attempt number"
  [base-delay attempt]
  (letfn [(fib [n]
            (if (<= n 1)
              n
              (+ (fib (- n 1)) (fib (- n 2)))))]
    (* base-delay (fib (inc attempt)))))

(defn calculate-base-delay
  "Calculate base delay before jitter based on strategy and attempt"
  [strategy base-delay attempt]
  (case strategy
    "linear" (* base-delay (inc attempt))
    "exponential" (* base-delay (Math/pow 2 attempt))
    "fibonacci" (calculate-fibonacci-delay base-delay attempt)
    "fixed" base-delay))

(defn apply-jitter
  "Apply jitter to the calculated delay"
  [jitter-type delay]
  (long
   (case jitter-type
     "none" delay
     "full" (rand-int (inc (long delay)))
     "equal" (+ (/ delay 2) (rand-int (inc (long (/ delay 2)))))
     "decorrelated" (let [min-delay (max 1 (/ delay 4))
                          max-delay (* delay 2)]
                      (+ min-delay (rand-int (long (- max-delay min-delay))))))))

(defn should-retry?
  "Determine if we should retry based on exit code and configuration"
  [exit-code non-retryable-codes]
  (not (contains? non-retryable-codes exit-code)))

(defn format-command
  "Format command for display and execution"
  [command-args]
  (if (= 1 (count command-args))
    (first command-args)
    (str/join " " (map #(if (str/includes? % " ") (str "\"" % "\"") %) command-args))))

(def ^:dynamic *interrupted* (atom false))

(defn setup-signal-handlers
  "Setup signal handlers for graceful shutdown"
  []
  (try
    (.addShutdownHook (Runtime/getRuntime)
                      (Thread. #(do
                                  (reset! *interrupted* true)
                                  (println "\nReceived interrupt signal. Stopping after current attempt..."))))
    (catch Exception e
      ;; Ignore if shutdown hook already exists or can't be added
      nil)))

(defn check-interruption
  "Check if the process has been interrupted"
  []
  (when @*interrupted*
    (throw (ex-info "Process interrupted by user" {:interrupted true}))))

(defn interruptible-sleep
  "Sleep for the given duration but check for interruption every 100ms"
  [duration-ms]
  (when (> duration-ms 0)
    (let [sleep-interval 100
          iterations (long (/ duration-ms sleep-interval))
          remainder (long (mod duration-ms sleep-interval))]
      (dotimes [_ iterations]
        (check-interruption)
        (Thread/sleep sleep-interval))
      (when (> remainder 0)
        (check-interruption)
        (Thread/sleep remainder)))))

(defn execute-with-retry
  "Main retry logic with backoff, jitter, and timeout handling"
  [command-args opts]
  (let [{:keys [max-attempts backoff-strategy base-delay max-delay jitter
                timeout-per-attempt total-timeout non-retryable-codes verbose dry-run]} opts
        command-str (format-command command-args)
        start-time (System/currentTimeMillis)]

    ;; Setup signal handlers (temporarily disabled due to babashka issue)
    ;; (setup-signal-handlers)

    (when verbose
      (println (str "Executing: " command-str))
      (println (str "Strategy: " backoff-strategy ", Jitter: " jitter ", Max attempts: " max-attempts)))

    (if dry-run
      (do
        (println (str "Would execute: " command-str))
        (println (str "With " max-attempts " attempts using " backoff-strategy " backoff and " jitter " jitter"))
        {:exit 0 :out "Dry run completed" :err ""})

      (loop [attempt 0]
        (let [current-time (System/currentTimeMillis)
              elapsed-time (- current-time start-time)]

          ;; Check for interruption (temporarily disabled)
          ;; (check-interruption)

          ;; Check total timeout
          (when (and total-timeout (> elapsed-time total-timeout))
            (when verbose (println (str "Total timeout of " total-timeout "ms exceeded")))
            (throw (ex-info "Total timeout exceeded" {:elapsed elapsed-time :timeout total-timeout})))

          (when verbose
            (println (str "Attempt " (inc attempt) "/" max-attempts)))

          ;; Execute command
          (let [result (try
                         (let [cmd-opts (cond-> {:out :string :err :string}
                                          timeout-per-attempt (assoc :timeout timeout-per-attempt))]
                           (apply p/shell cmd-opts command-args))
                         (catch Exception e
                           {:exit 1 :err (.getMessage e) :out ""}))]

            (when verbose
              (println (str "Exit code: " (:exit result)))
              (when (not (str/blank? (:err result)))
                (println (str "stderr: " (str/trim (:err result))))))

            ;; Check if successful or shouldn't retry
            (cond
              ;; Success
              (= 0 (:exit result))
              (do
                (when verbose (println "Command succeeded"))
                result)

              ;; Non-retryable exit code
              (not (should-retry? (:exit result) non-retryable-codes))
              (do
                (when verbose (println (str "Exit code " (:exit result) " is non-retryable")))
                result)

              ;; Max attempts reached
              (>= attempt (dec max-attempts))
              (do
                (when verbose (println "Max attempts reached"))
                result)

              ;; Retry with backoff
              :else
              (let [base-delay-ms (calculate-base-delay backoff-strategy base-delay attempt)
                    capped-delay (min base-delay-ms max-delay)
                    final-delay (apply-jitter jitter capped-delay)]

                (when verbose
                  (println (str "Retrying in " final-delay "ms...")))

                (Thread/sleep final-delay)
                (recur (inc attempt))))))))))

(defn parse-non-retryable-codes [codes-str]
  "Parse comma-separated exit codes into a set"
  (if (string? codes-str)
    (set (map parse-long (str/split codes-str #",")))
    codes-str))

(defn validate-options [opts]
  "Validate parsed options and return with defaults"
  (let [validated (merge default-config opts)]
    (cond
      (not (contains? #{"linear" "exponential" "fibonacci" "fixed"} (:backoff-strategy validated)))
      (throw (ex-info "Invalid backoff strategy" {:strategy (:backoff-strategy validated)}))

      (not (contains? #{"full" "equal" "decorrelated" "none"} (:jitter validated)))
      (throw (ex-info "Invalid jitter type" {:jitter (:jitter validated)}))

      :else
      (update validated :non-retryable-codes parse-non-retryable-codes))))

(defn show-help []
  (println "retry - Advanced retry script with backoff strategies and jitter")
  (println)
  (println "Usage: retry [options] <command>")
  (println)
  (println "Options:")
  (println "  --max-attempts <num>         Maximum number of retry attempts (default: 5)")
  (println "  --backoff-strategy <type>    Backoff strategy: linear, exponential, fibonacci, fixed (default: exponential)")
  (println "  --base-delay <ms>            Base delay in milliseconds (default: 1000)")
  (println "  --max-delay <ms>             Maximum delay in milliseconds (default: 30000)")
  (println "  --jitter <type>              Jitter type: full, equal, decorrelated, none (default: equal)")
  (println "  --timeout-per-attempt <ms>   Timeout per attempt in milliseconds")
  (println "  --total-timeout <ms>         Total timeout for all attempts in milliseconds")
  (println "  --non-retryable-codes <list> Comma-separated exit codes that should not be retried (default: 126,127)")
  (println "  --verbose                    Enable verbose logging")
  (println "  --dry-run                    Show what would be executed without running commands")
  (println "  --help, -h                   Show this help")
  (println)
  (println "Examples:")
  (println "  retry curl https://httpbin.org/status/500")
  (println "  retry --verbose -- curl --fail https://httpbin.org/status/500")
  (println "  retry --max-attempts 10 --backoff-strategy fibonacci -- ping -c 1 8.8.8.8")
  (println "  retry --base-delay 500 --total-timeout 30000 -- ssh user@host 'command --with --flags'")
  (println "  retry --dry-run --verbose -- echo 'test command'")
  (println)
  (println "Note: Use '--' to separate retry options from the command and its arguments.")
  (println "      Without '--', any argument starting with '--' will be treated as a retry option."))

(defn -main [& args]
  (cond
    ;; Check for help flag directly
    (or (some #{"--help" "-h"} args) (empty? args))
    (do (show-help) (System/exit (if (empty? args) 1 0)))

    :else
    (try
      ;; Parse arguments properly - separate retry options from command
      (let [retry-options #{"--verbose" "--dry-run" "--max-attempts" "--backoff-strategy" 
                            "--base-delay" "--max-delay" "--jitter" "--timeout-per-attempt"
                            "--total-timeout" "--non-retryable-codes"}
            {parsed-opts :opts command-args :args} 
            (loop [remaining args
                   opts {}
                   cmd-args []]
              (cond
                ;; Hit the -- separator, rest are command args
                (= "--" (first remaining))
                {:opts opts :args (vec (rest remaining))}
                
                ;; No more args
                (empty? remaining)
                {:opts opts :args cmd-args}
                
                ;; Found a retry option
                (contains? retry-options (first remaining))
                (let [opt (first remaining)
                      has-value? (contains? #{"--max-attempts" "--backoff-strategy" "--base-delay" 
                                              "--max-delay" "--jitter" "--timeout-per-attempt"
                                              "--total-timeout" "--non-retryable-codes"} opt)]
                  (if has-value?
                    (if (< 1 (count remaining))
                      (recur (drop 2 remaining) 
                             (assoc opts opt (second remaining))
                             cmd-args)
                      (throw (ex-info (str "Option " opt " requires a value") {})))
                    (recur (rest remaining)
                           (assoc opts opt true)
                           cmd-args)))
                
                ;; Not a retry option, must be part of command
                :else
                (recur (rest remaining) opts (conj cmd-args (first remaining)))))
            
            opts (merge default-config
                       (cond-> {}
                         (contains? parsed-opts "--verbose") (assoc :verbose true)
                         (contains? parsed-opts "--dry-run") (assoc :dry-run true)
                         (contains? parsed-opts "--max-attempts") (assoc :max-attempts (parse-long (get parsed-opts "--max-attempts")))
                         (contains? parsed-opts "--backoff-strategy") (assoc :backoff-strategy (get parsed-opts "--backoff-strategy"))
                         (contains? parsed-opts "--base-delay") (assoc :base-delay (parse-long (get parsed-opts "--base-delay")))
                         (contains? parsed-opts "--max-delay") (assoc :max-delay (parse-long (get parsed-opts "--max-delay")))
                         (contains? parsed-opts "--jitter") (assoc :jitter (get parsed-opts "--jitter"))
                         (contains? parsed-opts "--timeout-per-attempt") (assoc :timeout-per-attempt (parse-long (get parsed-opts "--timeout-per-attempt")))
                         (contains? parsed-opts "--total-timeout") (assoc :total-timeout (parse-long (get parsed-opts "--total-timeout")))
                         (contains? parsed-opts "--non-retryable-codes") (assoc :non-retryable-codes (get parsed-opts "--non-retryable-codes"))))]
        (when (empty? command-args)
          (println "Error: No command provided")
          (System/exit 1))

        (let [result (execute-with-retry command-args opts)]
          (when (:verbose opts)
            (println (str "Final exit code: " (:exit result))))
          (System/exit (:exit result))))
      (catch Exception e
        (println "Error:" (.getMessage e))
        (when *command-line-args*
          (println "Args:" *command-line-args*))
        (.printStackTrace e)
        (System/exit 1)))))

;; Execute when script is run directly
(when (= *file* (System/getProperty "babashka.file"))
  (apply -main *command-line-args*))