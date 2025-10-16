# AWS development tools
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.aws;
in
{
  options.hmFoundry.dev.aws = {
    enable = mkEnableOption "AWS development tools";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      awscli2
    ];
  };
}
