# Docker and container tools
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.docker;
in
{
  options.hmFoundry.dev.docker = {
    enable = mkEnableOption "Docker and container tools";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      docker-compose
    ];
  };
}
