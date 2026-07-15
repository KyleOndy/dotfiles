# Desktop environment configuration
# Used by profiles that need GUI applications and desktop environments

{
  pkgs,
  lib,
  config,
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
        backup-photos # syncs ~/photos to tiger and S3 Deep Archive
        golden-cheetah # cycling analytics
        keymapp # zsa keyboard config
        remmina # remote desktop client
        vlc # watch things
      ];

    # helios defaults its dedup db to XDG_STATE_HOME, but the canonical
    # database (56k+ imports) lives with the library it tracks. Point it
    # there explicitly so a fresh XDG_STATE_HOME never starts an empty db
    # and reimports everything.
    home.sessionVariables = mkIf pkgs.stdenv.isLinux {
      HELIOS_DB_PATH = "${config.home.homeDirectory}/photos/helios.db";
      PHOTOS_DIR = "${config.home.homeDirectory}/photos";
    };
  };
}
