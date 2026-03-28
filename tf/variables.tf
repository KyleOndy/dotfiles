variable "elk_apps_subdomains" {
  type = list(string)
  default = [
    "grafana",
    "loki",
    "metrics",
    "vmalert",

    # media
    "bazarr",
    "jellyfin",
    "jellyseerr",
    "lidarr",
    "navidrome",
    "prowlarr",
    "radarr",
    "readarr",
    "sabnzbd",
    "sonarr",
  ]
}
