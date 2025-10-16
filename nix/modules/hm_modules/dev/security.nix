# Security and secrets management tools
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.security;
in
{
  options.hmFoundry.dev.security = {
    enable = mkEnableOption "Security and secrets management tools";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      age
      sops
      openvpn
      zbar
    ];
  };
}
