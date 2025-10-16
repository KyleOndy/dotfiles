# System administration and monitoring tools
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.sysadmin;
in
{
  options.hmFoundry.dev.sysadmin = {
    enable = mkEnableOption "System administration and monitoring tools";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      htop
      lsof
      nettools
      dnsutils
      nmap
      mosh
    ];
  };
}
