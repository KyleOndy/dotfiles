# Additional development tools that don't fit in other categories
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev;
in
{
  config = mkIf cfg.enable {
    home.packages =
      with pkgs;
      [
        # GitHub integration
        act

        # Fonts
        berkeley-mono
        pragmata-pro

        # Terminal tools
        ncspot

        # Additional Clojure tools (always with dev for now)
        babashka-scripts
      ]
      ++ lib.optionals stdenv.isLinux [
        # Linux-specific tools and system utilities
        atop
        babashka
        calcurse
        inotify-tools
        ltrace
        molly-guard
        pciutils
        qemu_full
        squashfsTools
        virt-manager
      ];
  };
}
