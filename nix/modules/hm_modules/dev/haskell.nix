{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.haskell;
in
{
  options.hmFoundry.dev.haskell = {
    enable = mkEnableOption "haskell stuff";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      cabal-install
      ghc # Glasgow Haskell compiler
      stack # haskell build tooling
    ];
  };
}
