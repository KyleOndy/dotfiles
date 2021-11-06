{ lib, pkgs, config, ... }:
with lib;
let cfg = config.foundry.dev.haskell;
in
{
  options.foundry.dev.haskell = {
    enable = mkEnableOption "haskell";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [ cabal-install ];
  };
}
