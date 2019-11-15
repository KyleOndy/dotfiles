# todo: add Haskell configuration
{ pkgs, ... }: {
  home.packages = with pkgs; [ cabal-install ];
}
