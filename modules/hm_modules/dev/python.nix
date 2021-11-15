{ lib, pkgs, config, ... }:
with lib;
let
  cfg = config.hmFoundry.dev.python;
  python-packages = python-packages: with python-packages; [ virtualenv ];
  system-python-with-packages = pkgs.python3.withPackages python-packages;
in
{
  options.hmFoundry.dev.python = {
    enable = mkEnableOption "python";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      system-python-with-packages
      nodePackages.pyright
    ];
  };
}
