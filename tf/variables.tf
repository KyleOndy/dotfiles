variable "ondy_org_top_level_apps" {
  type = list(string)
  default = [
    "git",
  ]
}

variable "ondy_org_apps_subdomains" {
  type = list(string)
  default = [
    "metrics",
    "loki",
    "grafana",
    "nix-cache",
  ]
}
