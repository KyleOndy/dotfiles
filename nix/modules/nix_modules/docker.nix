{ lib, pkgs, config, ... }:
with lib;
let cfg = config.systemFoundry.docker;
in
{
  options.systemFoundry.docker = {
    enable = mkEnableOption ''
      docker
    '';
  };

  config = mkIf cfg.enable {
    virtualisation.docker = {
      enable = true;
    };
  };
}


