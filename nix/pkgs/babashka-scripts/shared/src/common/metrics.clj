(ns common.metrics
  "Prometheus-compatible metrics collection for Babashka scripts"
  (:require
   [clojure.string :as str]))

(defonce metrics-registry
  (atom {}))

(defn- sanitize-label-value
  "Sanitize a label value for Prometheus format"
  [value]
  (-> (str value)
      (str/replace #"\\" "\\\\")
      (str/replace #"\"" "\\\"")
      (str/replace #"\n" "\\n")))

(defn- format-labels
  "Format labels map for Prometheus text format"
  [labels]
  (when (seq labels)
    (str "{"
         (->> labels
              (map (fn [[k v]]
                     (format "%s=\"%s\""
                             (name k)
                             (sanitize-label-value v))))
              (str/join ","))
         "}")))

(defn counter
  "Create or get a counter metric"
  [name help]
  (let [metric-key (keyword name)]
    (when-not (get @metrics-registry metric-key)
      (swap! metrics-registry assoc metric-key
             {:type :counter
              :help help
              :name name
              :values (atom {})}))
    metric-key))

(defn gauge
  "Create or get a gauge metric"
  [name help]
  (let [metric-key (keyword name)]
    (when-not (get @metrics-registry metric-key)
      (swap! metrics-registry assoc metric-key
             {:type :gauge
              :help help
              :name name
              :values (atom {})}))
    metric-key))

(defn histogram
  "Create or get a histogram metric"
  [name help buckets]
  (let [metric-key (keyword name)]
    (when-not (get @metrics-registry metric-key)
      (swap! metrics-registry assoc metric-key
             {:type :histogram
              :help help
              :name name
              :buckets buckets
              :values (atom {})}))
    metric-key))

(defn- get-label-key
  "Generate a unique key for a set of labels"
  [labels]
  (if (empty? labels)
    :_default
    (keyword (pr-str (into (sorted-map) labels)))))

(defn inc-counter
  "Increment a counter metric"
  ([metric-key]
   (inc-counter metric-key {} 1))
  ([metric-key labels]
   (inc-counter metric-key labels 1))
  ([metric-key labels amount]
   (when-let [metric (get @metrics-registry metric-key)]
     (let [label-key (get-label-key labels)]
       (swap! (:values metric)
              update label-key
              (fn [current]
                (+ (or current 0) amount)))))))

(defn set-gauge
  "Set a gauge metric value"
  [metric-key labels value]
  (when-let [metric (get @metrics-registry metric-key)]
    (let [label-key (get-label-key labels)]
      (swap! (:values metric) assoc label-key value))))

(defn observe-histogram
  "Observe a value in a histogram"
  [metric-key labels value]
  (when-let [metric (get @metrics-registry metric-key)]
    (let [label-key (get-label-key labels)
          buckets (:buckets metric)]
      (swap! (:values metric)
             update label-key
             (fn [current]
               (let [counts (or (:counts current) (vec (repeat (count buckets) 0)))
                     sum (+ (or (:sum current) 0) value)
                     cnt (inc (or (:count current) 0))
                     new-counts (reduce
                                 (fn [acc i]
                                   (if (<= value (nth buckets i))
                                     (update acc i inc)
                                     acc))
                                 counts
                                 (range (count buckets)))]
                 {:counts new-counts
                  :sum sum
                  :count cnt}))))))

(defn- format-counter
  "Format a counter metric for Prometheus text format"
  [metric]
  (let [{:keys [name help values]} metric
        metric-name name
        values-snapshot @values]
    (str "# HELP " metric-name " " help "\n"
         "# TYPE " metric-name " counter\n"
         (->> values-snapshot
              (map (fn [[label-key value]]
                     (let [labels (when-not (= label-key :_default)
                                    (read-string (clojure.core/name label-key)))]
                       (str metric-name (format-labels labels) " " value))))
              (str/join "\n")))))

(defn- format-gauge
  "Format a gauge metric for Prometheus text format"
  [metric]
  (let [{:keys [name help values]} metric
        metric-name name
        values-snapshot @values]
    (str "# HELP " metric-name " " help "\n"
         "# TYPE " metric-name " gauge\n"
         (->> values-snapshot
              (map (fn [[label-key value]]
                     (let [labels (when-not (= label-key :_default)
                                    (read-string (clojure.core/name label-key)))]
                       (str metric-name (format-labels labels) " " value))))
              (str/join "\n")))))

(defn- format-histogram
  "Format a histogram metric for Prometheus text format"
  [metric]
  (let [{:keys [name help values buckets]} metric
        metric-name name
        values-snapshot @values]
    (str "# HELP " metric-name " " help "\n"
         "# TYPE " metric-name " histogram\n"
         (->> values-snapshot
              (mapcat (fn [[label-key data]]
                        (let [labels (when-not (= label-key :_default)
                                       (read-string (clojure.core/name label-key)))
                              {:keys [counts sum count]} data
                              cnt count
                              bucket-lines (map-indexed
                                            (fn [i bucket]
                                              (let [bucket-labels (assoc labels :le (str bucket))]
                                                (str metric-name "_bucket" (format-labels bucket-labels)
                                                     " " (get counts i 0))))
                                            buckets)
                              inf-line (str metric-name "_bucket" (format-labels (assoc labels :le "+Inf"))
                                            " " cnt)
                              sum-line (str metric-name "_sum" (format-labels labels) " " sum)
                              count-line (str metric-name "_count" (format-labels labels) " " cnt)]
                          (concat bucket-lines [inf-line sum-line count-line]))))
              (str/join "\n")))))

(defn export-metrics
  "Export all metrics in Prometheus text format"
  []
  (->> @metrics-registry
       vals
       (map (fn [metric]
              (case (:type metric)
                :counter (format-counter metric)
                :gauge (format-gauge metric)
                :histogram (format-histogram metric))))
       (str/join "\n\n")))

(defn reset-metrics
  "Reset all metrics to zero (useful for testing)"
  []
  (doseq [[_ metric] @metrics-registry]
    (reset! (:values metric) {})))

(defn clear-registry
  "Clear the entire metrics registry (useful for testing)"
  []
  (reset! metrics-registry {}))

(defmacro time-histogram
  "Time the execution of body and record in histogram"
  [metric-key labels & body]
  `(let [start# (System/nanoTime)
         result# (do ~@body)
         duration# (/ (- (System/nanoTime) start#) 1e9)]
     (observe-histogram ~metric-key ~labels duration#)
     result#))

(comment
  ;; Example usage
  (def downloads-total (counter "yt_downloads_total" "Total number of downloads"))
  (def errors-total (counter "yt_errors_total" "Total number of errors"))
  (def processing-time (histogram "yt_processing_seconds"
                                  "Time spent processing channels"
                                  [1 5 10 30 60 120 300]))

  (inc-counter downloads-total {:status "success" :channel "@example"})
  (inc-counter downloads-total {:status "failed" :channel "@example2"})
  (inc-counter errors-total {:type "rate_limit"})

  (observe-histogram processing-time {:channel "@example"} 45.2)

  (println (export-metrics))

  (reset-metrics))
