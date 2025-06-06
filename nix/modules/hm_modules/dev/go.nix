{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.dev.go;
in
{
  options.hmFoundry.dev.go = {
    enable = mkEnableOption "golang";
  };

  config = mkIf cfg.enable {
    programs.go = {
      enable = true;
      package = pkgs.go;
    };
  };
}
