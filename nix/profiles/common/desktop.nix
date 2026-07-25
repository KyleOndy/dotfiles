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
    hmFoundry.desktop = {
      browsers.firefox.enable = true;
      term.alacritty.enable = pkgs.stdenv.isDarwin;

      # Linux-only, guarded here so the Macs do not each have to turn six
      # things back off by hand. makemkv stays off everywhere: makemkv.com
      # returns 403 on its tarball downloads, which breaks every
      # desktop-profile build (tiger). Re-enable once upstream fixes the
      # mirror or the derivation moves to a working source.
      apps.discord.enable = pkgs.stdenv.isLinux;
      apps.slack.enable = pkgs.stdenv.isLinux;
      gaming.steam.enable = pkgs.stdenv.isLinux;
      media.documents.enable = pkgs.stdenv.isLinux;
      term.foot.enable = pkgs.stdenv.isLinux;
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
