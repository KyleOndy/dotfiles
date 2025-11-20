{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.desktop.apps.teams;
in
{
  options.hmFoundry.desktop.apps.teams = {
    enable = mkEnableOption "Microsoft Teams (unofficial teams-for-linux client)";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      teams-for-linux
    ];
  };
}
