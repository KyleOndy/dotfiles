# Advanced monitoring and diagnostic tools
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.monitoring;
in
{
  options.hmFoundry.dev.monitoring = {
    enable = mkEnableOption "Advanced monitoring and diagnostic tools";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      glances
      viddy
      watch
      pv
    ];
  };
}
