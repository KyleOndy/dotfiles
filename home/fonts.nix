{ pkgs, ... }:

{
  # todo: why do I need to set mkForce?
  # This change was needed when I cutover from using submodules to niv to track
  # dependencies. Something in that process has seemed to change the order
  # these settings are applied. When I understand NixOS/Nix better I'd like to
  # circle back and look into this.
  fonts.fontconfig.enable = pkgs.lib.mkForce true;

  home.packages = with pkgs; [
    hack-font # used in st
  ];
}
