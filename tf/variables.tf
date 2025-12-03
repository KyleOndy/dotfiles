variable "ondy_org_top_level_apps" {
  type = list(string)
  default = [
    "git",
  ]
}

variable "wolf_apps_subdomains" {
  type = list(string)
  default = [
    "grafana",
    "loki",
    "metrics",
    "nix-cache",
    "vmalert",

    # media managment
    "bazarr",
    "jellyseerr",
    "lidarr",
    "prowlarr",
    "radarr",
    "readarr",
    "sabnzbd",
    "sonarr",
    "tdarr",
  ]
}

variable "bear_apps_subdomains" {
  type = list(string)
  default = [
    "jellyfin",
  ]
}
