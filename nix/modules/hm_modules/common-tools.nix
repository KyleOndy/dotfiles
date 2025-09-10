{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.commonTools;
in
{
  options.hmFoundry.commonTools = {
    enable = mkEnableOption "common tools used across multiple profiles";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      # Search and navigation
      ripgrep
      fd
      tree
      bat

      # Network tools
      curl
      wget
      rsync

      # Data processing
      jq
      yq-go
    ];
  };
}
