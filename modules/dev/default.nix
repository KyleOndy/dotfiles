# this module is a catch all for general development things. As needed I will
# break related configurations out of this file into its own module., I also
# try to not get carried away for the sake of it.

{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.dev;
in
{
  options.foundry.dev = {
    enable = mkEnableOption "General development utilities and configuration";
  };

  config = mkIf cfg.enable {
    programs = {
      bat = {
        enable = true;
        config = {
          theme = "gruvbox-dark";
        };
      };
      direnv = {
        enable = true;
        nix-direnv = {
          enable = true;
          enableFlakes = true;
        };
      };
    };
  };
}
