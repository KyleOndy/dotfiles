# Desktop environment configuration
# Used by profiles that need GUI applications and desktop environments

{
  pkgs,
  lib,
  ...
}:
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
          # Disabled: makemkv.com returns 403 on its tarball downloads, breaking
          # every desktop-profile build (dino, tiger). Re-enable once upstream
          # fixes the mirror or the derivation is updated to a working source.
          makemkv.enable = false;
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
        keymapp # zsa keyboard config
        remmina # remote desktop client
        vlc # watch things
      ];
  };
}
