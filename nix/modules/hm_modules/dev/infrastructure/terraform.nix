# Terraform and infrastructure as code tools
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.features;
  devCfg = config.hmFoundry.dev;
in
{
  config = mkIf (devCfg.enable && cfg.isTerraform) {
    home.packages = with pkgs; [
      terraform_1
    ];
  };
}
