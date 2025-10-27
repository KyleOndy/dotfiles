(ns common.metrics-server
  "Simple HTTP server for exposing Prometheus metrics"
  (:require
    [clojure.string :as str]
    [common.logging :as log]
    [common.metrics :as metrics])
  (:import
    (java.io
      BufferedReader
      InputStreamReader
      PrintWriter)
    (java.net
      InetSocketAddress
      ServerSocket)))


;; Atom holding server state
(defonce ^:private server-state
  (atom {:running false
         :server-socket nil
         :thread nil}))


(defn- handle-request
  "Handle an HTTP request"
  [socket]
  (try
    (with-open [in (BufferedReader. (InputStreamReader. (.getInputStream socket)))
                out (PrintWriter. (.getOutputStream socket) true)]
      (let [request-line (.readLine in)
            [method path] (when request-line
                            (str/split request-line #"\s+"))]

        ;; Read and discard headers
        (loop []
          (let [line (.readLine in)]
            (when (and line (not (str/blank? line)))
              (recur))))

        ;; Handle request based on path
        (cond
          (and (= method "GET") (= path "/metrics"))
          (let [metrics-output (metrics/export-metrics)]
            (.println out "HTTP/1.1 200 OK")
            (.println out "Content-Type: text/plain; version=0.0.4")
            (.println out (str "Content-Length: " (count metrics-output)))
            (.println out "")
            (.print out metrics-output)
            (.flush out))

          (and (= method "GET") (= path "/health"))
          (do
            (.println out "HTTP/1.1 200 OK")
            (.println out "Content-Type: text/plain")
            (.println out "Content-Length: 2")
            (.println out "")
            (.print out "OK")
            (.flush out))

          :else
          (do
            (.println out "HTTP/1.1 404 Not Found")
            (.println out "Content-Type: text/plain")
            (.println out "Content-Length: 9")
            (.println out "")
            (.print out "Not Found")
            (.flush out)))))
    (catch Exception e
      (log/debug "Error handling request" {:error (.getMessage e)}))
    (finally
      (try
        (.close socket)
        (catch Exception _)))))


(defn- accept-loop
  "Main server loop accepting connections"
  [server-socket]
  (log/info "Metrics server started" {:port (.getLocalPort server-socket)})
  (while (not (.isClosed server-socket))
    (try
      (let [client-socket (.accept server-socket)]
        ;; Handle request in a new thread
        (future (handle-request client-socket)))
      (catch java.net.SocketException _
        ;; Server was closed, exit loop
        nil)
      (catch Exception e
        (log/error "Error accepting connection" {:error (.getMessage e)})))))


(defn start-server
  "Start the metrics HTTP server on the specified port"
  [port]
  (when (:running @server-state)
    (throw (ex-info "Server is already running" {})))

  (try
    (let [server-socket (ServerSocket.)
          _ (.setReuseAddress server-socket true)
          _ (.bind server-socket (InetSocketAddress. port))
          server-thread (Thread. #(accept-loop server-socket))]

      (.setDaemon server-thread true)
      (.start server-thread)

      (swap! server-state assoc
             :running true
             :server-socket server-socket
             :thread server-thread)

      (log/info "Metrics server thread started" {:port port})
      true)
    (catch Exception e
      (log/error "Failed to start metrics server" {:error (.getMessage e)})
      (throw e))))


(defn stop-server
  "Stop the metrics HTTP server"
  []
  (when-let [server-socket (:server-socket @server-state)]
    (try
      (.close server-socket)
      (log/info "Metrics server stopped")
      (swap! server-state assoc
             :running false
             :server-socket nil
             :thread nil)
      true
      (catch Exception e
        (log/error "Error stopping server" {:error (.getMessage e)})
        false))))


(defn running?
  "Check if the server is running"
  []
  (:running @server-state))


(defmacro with-metrics-server
  "Run body with a metrics server running in the background"
  [port & body]
  `(do
     (start-server ~port)
     (try
       ~@body
       (finally
         (stop-server)))))


(comment
  ;; Example usage
  ;; Note: common.metrics is already required as 'metrics' in the ns form

  (def test-counter (metrics/counter "test_counter" "A test counter"))
  (metrics/inc-counter test-counter {:label "value1"})

  (start-server 9091)
  ;; Now curl http://localhost:9091/metrics
  ;; curl http://localhost:9091/health

  (stop-server))
