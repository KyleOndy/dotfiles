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
#
# from= is the LAN plus the WireGuard pool (nix/hosts/trex/wireguard.nix).
# trex reaches these hosts only through names the UDM serves, so off the LAN
# without the tunnel it has no route to them anyway.
[
  "from=\"10.24.89.0/24,192.168.5.0/24\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJl9x835n7Sw4zbxo0bVGNsp0i3cITyYg6WOMj2DBkf kyle@trex.lan.1ella.com"
  "from=\"10.24.89.0/24,192.168.5.0/24\" ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDFg44/Nh3mgJT4aRqdncqxOmsH9V97VAfrIWD0x0zprwTXkpuZilH0AAJQeh5HmYJ4vlklBHskE5L0k5DXHKLjrwgMO40lsiMjoHOHTH09D9aUSrrJb6fxKricOQ2cM6pEzavlICJ+qtLmay/Z+WRICc1t7zYhiXkRmyTaFMBH08T6MAsZ4GDzHS6HvNq9mDDxeVSfeU9AUJPJ2yHu6zRrasb3nIxdcf1ibw5XZeXEoZU45zYO1lp/9KoM3Fem9qAjcXWg9aoArFS70/pgkiE7GpPH02DT84rF8FISD3uzJD7GdGH+aedSA+6QzV4/DZaJEHe8kdtugeR9xGsS56yb cardno:11_583_059"
]
