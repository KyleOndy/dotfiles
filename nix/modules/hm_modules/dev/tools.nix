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
        ghostty
        keymapp
        ncspot
        vlc

        # System utilities
        pciutils
        squashfsTools

        # Additional Clojure tools (always with dev for now)
        babashka-scripts
      ]
      ++ lib.optionals stdenv.isLinux [
        # Linux-specific tools
        atop
        babashka
        calcurse
        inotify-tools
        ltrace
        molly-guard
        qemu_full
        virt-manager
      ];
  };
}
