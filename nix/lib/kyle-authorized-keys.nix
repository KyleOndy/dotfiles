# Kyle's personal SSH public keys, trusted for the kyle and svc.deploy
# accounts across the NixOS fleet.
#
# Plain data rather than only a module option, because pika's installer ISO
# needs the same list and cannot import kyle.nix: that module defines
# sops.secrets under an mkIf, and the module system requires the option to
# exist even when the condition is false.
#
# It sits outside nix/modules because flake.nix globs every .nix file under
# nix_modules and imports it as a module. This one is a list.
[
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJl9x835n7Sw4zbxo0bVGNsp0i3cITyYg6WOMj2DBkf kyle@trex.lan.1ella.com"
]
