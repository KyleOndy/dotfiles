# Base configuration that all profiles should include
# Contains the absolute minimum requirements for any system

{
  pkgs,
  config,
  lib,
  ...
}:
with lib;
{
  config = {
    # Essential programs every profile needs
    programs = {
      home-manager.enable = true;
      lesspipe.enable = true;
    };

    # Essential services
    services = {
      # lorri only supports Linux
      lorri.enable = pkgs.stdenv.isLinux;
    };

    # Base environment setup
    home = {
      stateVersion = "18.09";

      # Only the most essential packages that every system needs
      packages = with pkgs; [
        coreutils-full
        findutils
        gnused
        gnumake
        man-pages
      ];
    };
  };
}
