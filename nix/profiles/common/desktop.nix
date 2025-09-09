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
          music.enable = true;
        };
        term = {
          wezterm.enable = true;
          foot.enable = true;
        };
      };
    };

    # Desktop-specific packages
    home.packages = with pkgs; [
      # Desktop applications
      deploy-rs # nixos deployment
      golden-cheetah # cycling analytics
      helios # hand rolled photo management
      remmina # remote desktop client
      glances # system monitor
    ];
  };
}
