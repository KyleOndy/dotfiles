variable "ondy_org_top_level_apps" {
  type = list(string)
  default = [
    "git",
  ]
}

variable "ondy_org_apps_subdomains" {
  type = list(string)
  default = [
    "grafana",
    "loki",
    "metrics",
    "nix-cache",
    "vmalert",

    # media managment
    "bazarr",
    "jellyfin",
    "jellyseerr",
    "lidarr",
    "prowlarr",
    "radarr",
    "readarr",
    "sabnzbd",
    "sonarr",
  ]
}
