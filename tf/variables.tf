
variable "tiger_apps_subdomains" {
  type = list(string)
  default = [
    # Only apps used away from home. Admin and monitoring UIs stay on the
    # LAN-only *.tiger.infra.ondy.org wildcard.
    "jellyfin",
    "jellyseerr",
    "navidrome",
    "immich",
  ]
}
