# Nix development and packaging tools
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
  config = mkIf (devCfg.enable && cfg.isNixDev) {
    home.packages = with pkgs; [
      nix-index
      nixfmt-rfc-style
      nixpkgs-fmt
      nixpkgs-review
    ];
  };
}
