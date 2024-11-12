{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.dev.dotnet;
in
{
  options.hmFoundry.dev.dotnet = {
    enable = mkEnableOption "dotnet";
  };

  config = mkIf cfg.enable {
    home.packages = [ pkgs.dotnet-runtime ];
  };
}
