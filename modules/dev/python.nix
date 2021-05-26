{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.dev.python;
in
{
  options.foundry.dev.python = {
    enable = mkEnableOption "python";
  };

  config = mkIf cfg.enable {
    home.packages = [ pkgs.nodePackages.pyright ];
  };
}
