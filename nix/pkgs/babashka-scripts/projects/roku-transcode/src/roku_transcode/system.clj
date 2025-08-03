(ns roku-transcode.system
  (:require
    [babashka.process :as p]
    [clojure.string :as str]))


(defn run-cmd
  "Run a shell command and return {:out :err :exit} map"
  [cmd & args]
  (try
    (let [result (apply p/shell {:out :string :err :string :continue true} cmd args)]
      {:out (:out result)
       :err (:err result)
       :exit (:exit result)})
    (catch Exception _
      {:out "" :err "" :exit 1})))


(defn has-nvidia-gpu?
  "Check if NVIDIA GPU is available"
  []
  (let [{:keys [exit out]} (run-cmd "nvidia-smi" "--query-gpu=name" "--format=csv,noheader")]
    (and (= 0 exit)
         (not (str/blank? out)))))


(defn get-nvidia-info
  "Get NVIDIA GPU information"
  []
  (when (has-nvidia-gpu?)
    (let [{:keys [out]} (run-cmd "nvidia-smi" "--query-gpu=name,driver_version,cuda_version" "--format=csv,noheader,nounits")]
      (when-not (str/blank? out)
        {:gpus (str/split-lines out)
         :driver-loaded? (-> (run-cmd "lsmod")
                             :out
                             (str/includes? "nvidia"))}))))


(defn get-drm-devices
  "Get available DRM devices for VAAPI"
  []
  (->> (run-cmd "sh" "-c" "ls /dev/dri/card* /dev/dri/renderD* 2>/dev/null || true")
       :out
       str/split-lines
       (remove str/blank?)
       (map (fn [device]
              {:path device
               :readable? (.canRead (java.io.File. device))
               :writable? (.canWrite (java.io.File. device))}))))


(defn get-vaapi-info
  "Get VAAPI information if available"
  []
  (let [{:keys [exit out]} (run-cmd "vainfo")]
    (when (= 0 exit)
      {:available? true
       :info (take 10 (str/split-lines out))})))


(defn get-gpu-info-pci
  "Get GPU information from PCI"
  []
  (let [{:keys [out]} (run-cmd "lspci")]
    (->> (str/split-lines out)
         (filter #(re-find #"(?i)(VGA|3D|Display)" %))
         (map str/trim))))


(defn detect-system-capabilities
  "Detect all system capabilities for encoding"
  []
  (let [nvidia-info (get-nvidia-info)
        drm-devices (get-drm-devices)
        vaapi-info (get-vaapi-info)
        pci-gpus (get-gpu-info-pci)]
    {:nvidia {:available? (boolean nvidia-info)
              :info nvidia-info}
     :drm-devices drm-devices
     :vaapi vaapi-info
     :pci-gpus pci-gpus
     :has-gpu-devices? (or (boolean nvidia-info)
                           (seq drm-devices))}))


(defn show-system-info
  "Display detailed system information"
  [capabilities]
  (println "=== System GPU Information ===")

  (if (get-in capabilities [:nvidia :available?])
    (do
      (println "NVIDIA GPU(s) detected:")
      (doseq [gpu (get-in capabilities [:nvidia :info :gpus])]
        (println " " gpu))
      (println "NVIDIA driver loaded:" (get-in capabilities [:nvidia :info :driver-loaded?])))
    (println "No NVIDIA GPU detected"))

  (println "DRM devices:")
  (if (seq (:drm-devices capabilities))
    (doseq [device (:drm-devices capabilities)]
      (println (format "  %s - %s"
                       (:path device)
                       (cond
                         (and (:readable? device) (:writable? device)) "read/write access"
                         (:readable? device) "readable"
                         :else "limited access"))))
    (println "  No DRM devices found"))

  (println "PCI GPU devices:")
  (if (seq (:pci-gpus capabilities))
    (doseq [gpu (:pci-gpus capabilities)]
      (println " " gpu))
    (println "  No GPU devices found via lspci"))

  (when (:vaapi capabilities)
    (println "VAAPI information:")
    (doseq [line (get-in capabilities [:vaapi :info])]
      (println " " line)))

  (println "================================"))
