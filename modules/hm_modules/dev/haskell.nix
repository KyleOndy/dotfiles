{ lib, pkgs, config, ... }:
with lib;
let cfg = config.hmFoundry.dev.haskell;
in
{
  options.hmFoundry.dev.haskell = {
    enable = mkEnableOption "haskell";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [ cabal-install ];
  };
}
