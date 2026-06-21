
variable "tiger_apps_subdomains" {
  type = list(string)
  default = [
    # media/downloader stack
    "bazarr",
    "jellyfin",
    "jellyseerr",
    "lidarr",
    "navidrome",
    "prowlarr",
    "radarr",
    "sabnzbd",
    "sonarr",

    # photos
    "immich",

    # monitoring stack
    "grafana",
    "loki",
    "metrics",
    "vmalert",
  ]
}
