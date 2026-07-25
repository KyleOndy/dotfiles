# The GUI layer, layered on top of server.nix by desktop.nix.
# Only trex and work-mac reach this, and both are Darwin.

{ pkgs, ... }:
{
  hmFoundry.desktop = {
    browsers.firefox.enable = true;
    term.alacritty.enable = true;
  };

  home.packages = with pkgs; [
    deploy-rs # nixos deployment
    glances # system monitor
    ncspot # cursors spotify client
  ];
}
