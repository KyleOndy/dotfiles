{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.apps.slack;
in
{
  options.hmFoundry.desktop.apps.slack = {
    enable = mkEnableOption "slack GUI client";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      slack
    ];
  };
}
