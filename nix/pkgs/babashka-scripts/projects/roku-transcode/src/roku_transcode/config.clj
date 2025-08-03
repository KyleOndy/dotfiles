(ns roku-transcode.config)


(def quality-presets
  {:high {:crf 20 :audio-bitrate "128k" :desc "best quality, larger file"}
   :medium {:crf 23 :audio-bitrate "128k" :desc "balanced"}
   :low {:crf 26 :audio-bitrate "96k" :desc "smaller file, lower quality"}})


(def encoders
  [{:name "h264_nvenc"
    :type :gpu
    :requires [:nvidia]
    :desc "NVIDIA GPU encoder"}
   {:name "h264_vaapi"
    :type :gpu
    :requires [:drm-devices]
    :desc "Intel/AMD VAAPI encoder"}
   {:name "h264_amf"
    :type :gpu
    :requires [:amd]
    :desc "AMD AMF encoder"}
   {:name "libx264"
    :type :cpu
    :requires []
    :desc "CPU encoder (fallback)"}])


(def default-options
  {:quality :high
   :force-gpu false
   :force-cpu false
   :verbose false
   :debug false
   :encoder nil})
