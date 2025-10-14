# Desktop environment configuration
# Used by profiles that need GUI applications and desktop environments

{ pkgs, lib, ... }:
with lib;
{
  config = {
    hmFoundry = {
      desktop = {
        apps = {
          discord.enable = true;
          slack.enable = true;
        };
        browsers = {
          firefox.enable = true;
        };
        gaming.steam.enable = true;
        media = {
          documents.enable = true;
          makemkv.enable = true;
        };
        term = {
          wezterm.enable = false;
          foot.enable = true;
        };
        wm.i3.enable = false;
      };
    };

    # Desktop-specific packages
    home.packages = with pkgs; [
      # Desktop applications
      deploy-rs # nixos deployment
      golden-cheetah # cycling analytics
      helios # hand rolled photo management
      remmina # remote desktop client
      vlc # watch things
      ghostty # terminal from mitchellh
      glances # system monitor
      keymapp # zsa keyboard config
      ncspot # cursors spotify client
    ];
  };
}
