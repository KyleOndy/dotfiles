{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.dev.dotnet;
in
{
  options.foundry.dev.dotnet = {
    enable = mkEnableOption "dotnet";
  };

  config = mkIf cfg.enable {
    home.packages = [ pkgs.dotnet-netcore ];
  };
}
