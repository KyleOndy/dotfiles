# Nix development and packaging tools
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.nixTools;
in
{
  options.hmFoundry.dev.nixTools = {
    enable = mkEnableOption "Nix development and packaging tools";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      nix-index
      nix-output-monitor
      nixfmt
      nixpkgs-fmt
      nixpkgs-review
    ];
  };
}
