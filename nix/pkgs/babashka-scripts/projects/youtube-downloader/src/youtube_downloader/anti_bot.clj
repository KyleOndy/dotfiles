(ns youtube-downloader.anti-bot
  "Bot detection mitigation strategies"
  (:require
    [clojure.string :as str]))


(def user-agents
  "Collection of common browser user agents to rotate"
  ["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
   "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
   "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
   "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0"
   "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.2) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"])


(defn random-user-agent
  "Get a random user agent string"
  []
  (rand-nth user-agents))


(defn random-delay
  "Sleep for a random duration between min and max seconds"
  [min-seconds max-seconds]
  (let [delay-ms (* 1000 (+ min-seconds (rand-int (- max-seconds min-seconds))))]
    (when (pos? delay-ms)
      (Thread/sleep delay-ms))
    delay-ms))


(defn calculate-channel-delay
  "Calculate delay between channels with jitter"
  [channel-index total-channels base-delay]
  (let [;; With only 5 videos per channel, we can use shorter delays
        min-delay 30   ; 30 seconds minimum
        max-delay 120  ; 2 minutes maximum

        ;; Progressive delay based on position
        progress-factor (/ channel-index (max 1 total-channels))
        progressive-delay (+ min-delay (* progress-factor (- max-delay min-delay)))

        ;; Add jitter
        jitter (* 0.3 progressive-delay (- (rand) 0.5))]

    (int (+ progressive-delay jitter))))


(defn exponential-backoff
  "Calculate exponential backoff delay for retries"
  [attempt & {:keys [base-delay max-delay jitter?]
              :or {base-delay 1000
                   max-delay 60000
                   jitter? true}}]
  (let [delay (* base-delay (Math/pow 2 attempt))
        capped-delay (min delay max-delay)]
    (long (if jitter?
            (+ capped-delay (rand-int (int (/ capped-delay 2))))
            capped-delay))))


(defn should-retry?
  "Determine if an error is retryable based on the error message"
  [error-msg]
  (cond
    ;; Rate limiting errors - definitely retry
    (re-find #"(?i)(429|too many requests|rate limit)" error-msg) true

    ;; Temporary network errors - retry
    (re-find #"(?i)(timeout|connection reset|temporary failure)" error-msg) true

    ;; Server errors - might be temporary
    (re-find #"(?i)(500|502|503|504|server error)" error-msg) true

    ;; Private/member content - don't retry
    (re-find #"(?i)(private|members? only|unavailable|deleted)" error-msg) false

    ;; Copyright/blocked - don't retry
    (re-find #"(?i)(copyright|blocked|restricted)" error-msg) false

    ;; Default - don't retry unknown errors
    :else false))


(defn parse-rate-limit-wait
  "Extract wait time from rate limit error if available"
  [error-msg]
  ;; YouTube sometimes tells us how long to wait
  (when-let [match (re-find #"(?i)retry after:? (\d+)" error-msg)]
    (* 1000 (Integer/parseInt (second match)))))


(defn handle-rate-limit
  "Handle rate limiting with appropriate backoff"
  [error-msg attempt]
  (let [suggested-wait (parse-rate-limit-wait error-msg)
        backoff-wait (exponential-backoff attempt :base-delay 5000 :max-delay 300000)]
    (if suggested-wait
      (do
        (println (format "Rate limited. Waiting %d seconds as requested..."
                         (/ suggested-wait 1000)))
        (Thread/sleep suggested-wait))
      (do
        (println (format "Rate limited. Waiting %d seconds (attempt %d)..."
                         (/ backoff-wait 1000)
                         (inc attempt)))
        (Thread/sleep backoff-wait)))))


(defn shuffle-channels
  "Randomize channel order to appear less predictable"
  [channels]
  (shuffle channels))


(defn adjust-limits-on-error
  "Reduce limits if we're hitting rate limits"
  [channel-config]
  (update channel-config :max-videos #(max 3 (quot % 2))))


(defn create-cookie-file
  "Create a temporary cookie file to maintain session"
  [data-dir]
  (let [cookie-file (str data-dir "/cookies.txt")]
    ;; yt-dlp will manage the actual cookies
    cookie-file))


(defn build-stealth-args
  "Build yt-dlp arguments for stealth operation"
  [data-dir]
  [;; Use cookies for session persistence
   "--cookies" (create-cookie-file data-dir)

   ;; Slow down requests
   "--sleep-requests" "1"
   "--sleep-interval" "2"
   "--max-sleep-interval" "5"

   ;; User agent rotation
   "--user-agent" (random-user-agent)

   ;; Avoid detection patterns
   "--no-check-certificates"
   "--no-warnings"
   "--quiet"
   "--no-progress"

   ;; Reduce parallel connections
   "--concurrent-fragments" "1"])


(defn detect-bot-challenge
  "Check if we're being challenged as a bot"
  [output]
  (re-find #"(?i)(captcha|challenge|verify|unusual activity|sign in to confirm)" output))
