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

    # Below stateVersion 20.09 these default to the evaluating shell's
    # XDG_*_HOME (https://github.com/nix-community/home-manager/blob/db7d5e2332710f5abb088f6b5de927d7f9511b35/modules/misc/xdg.nix#L174-L180),
    # so an alamode session, which sets its own, evaluated another generation.
    xdg = {
      cacheHome = "${config.home.homeDirectory}/.cache";
      configHome = "${config.home.homeDirectory}/.config";
      dataHome = "${config.home.homeDirectory}/.local/share";
      binHome = "${config.home.homeDirectory}/.local/bin";
      stateHome = "${config.home.homeDirectory}/.local/state";
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
        unzip
        zip
      ];
    };
  };
}
