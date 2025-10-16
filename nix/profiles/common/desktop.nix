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
    home.packages =
      with pkgs;
      [
        # Desktop applications
        deploy-rs # nixos deployment
        glances # system monitor
        ncspot # cursors spotify client
      ]
      ++ lib.optionals stdenv.isLinux [
        # Linux-only applications
        golden-cheetah # cycling analytics
        helios # hand rolled photo management
        keymapp # zsa keyboard config
        remmina # remote desktop client
        vlc # watch things
      ];
  };
}
