{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.dev.go;
in
{
  options.foundry.dev.go = {
    enable = mkEnableOption "golang";
  };

  config = mkIf cfg.enable {
    programs.go = {
      enable = true;
      package = pkgs.go;
      goPath = "go";
    };
  };
}
