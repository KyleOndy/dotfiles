{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.youtubeDownloader;
in
{
  options.systemFoundry.youtubeDownloader = {
    enable = mkEnableOption ''
      Automatically download youtube videos and cleanup after watching
    '';
    media_dir = mkOption {
      type = types.path;
      description = "Directory to media should be moved to";
      default = "/var/lib/youtube-downloader";
    };
    data_dir = mkOption {
      type = types.path;
      description = "Directory to store data";
      default = "/var/lib/youtube-downloader";
    };
    temp_dir = mkOption {
      type = types.path;
      description = "Directory to temporary files";
      default = "${cfg.data_dir}/temp";
    };
    delete_grace_period = mkOption {
      type = types.str;
      description = "Timespan to keep videos on jellyfin before deleting";
      default = "36 hours";
    };
    watched_channels = mkOption {
      type = types.listOf (types.either types.str types.attrs);
      description = "List of channels as strings or detailed configs";
      example = [
        "@regularChannel"
        {
          name = "@burstyChannel";
          max_videos = 20;
          download_shorts = true;
        }
      ];
    };
    sleep_between_channels = mkOption {
      type = types.int;
      description = "Seconds to sleep between channel downloads";
      default = 60;
    };
    download_shorts = mkOption {
      type = types.bool;
      description = "Global default for downloading YouTube Shorts (can be overridden per channel)";
      default = false;
    };
    max_videos_default = mkOption {
      type = types.int;
      description = ''
        Default number of recent videos to check per channel.
        This limits how far back yt-dlp looks, reducing API calls.
        Videos already in the archive are skipped automatically.
      '';
      default = 5;
    };
    max_videos_initial = mkOption {
      type = types.int;
      description = ''
        Number of videos to check on first run (when archive is empty).
        After initial population, max_videos_default is used.
      '';
      default = 30;
    };
  };

  config = mkIf cfg.enable {

    # Add babashka-scripts to system packages
    environment.systemPackages = [ pkgs.babashka-scripts ];

    systemd = {
      services.bgutil-pot-server = {
        enable = true;
        description = "bgutil PO token provider HTTP server for yt-dlp";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.bgutil-ytdlp-pot-server}/bin/bgutil-ytdlp-pot-server";
          Restart = "on-failure";
          RestartSec = "5s";
          DynamicUser = true;
          StateDirectory = "bgutil-pot-server";
        };
      };

      services.yt-download-and-clean = {
        enable = true;
        description = "Downloads Youtube videos and cleans up Jellyfin";
        startAt = "*-*-* 4:00:00"; # 4 am

        # Ensure bgutil PO token server is running before downloading
        wants = [ "bgutil-pot-server.service" ];
        after = [ "bgutil-pot-server.service" ];

        # Set environment variables for the Babashka script
        environment =
          let
            # Normalize channels to always be objects with complete settings
            normalizedChannels = map (
              ch:
              if builtins.isString ch then
                {
                  name = ch;
                  download_shorts = cfg.download_shorts;
                  max_videos = cfg.max_videos_default;
                }
              else
                {
                  name = ch.name;
                  download_shorts = ch.download_shorts or cfg.download_shorts;
                  max_videos = ch.max_videos or cfg.max_videos_default;
                }
            ) cfg.watched_channels;

            # yt-dlp (Python 3.13) discovers plugins via yt_dlp_plugins in sys.path.
            # PYTHONPATH is prepended to sys.path before the yt-dlp wrapper's site.addsitedir calls.
            # The bgutil HTTP plugin (getpot_bgutil_http.py) auto-connects to 127.0.0.1:4416.
            bgutil-plugin = pkgs.master.python313Packages.bgutil-ytdlp-pot-provider;
          in
          {
            YT_MEDIA_DIR = cfg.media_dir;
            YT_DATA_DIR = cfg.data_dir;
            YT_TEMP_DIR = cfg.temp_dir;
            YT_CHANNELS = builtins.toJSON normalizedChannels;
            YT_DOWNLOAD_SHORTS_DEFAULT = if cfg.download_shorts then "true" else "false";
            YT_MAX_VIDEOS_DEFAULT = toString cfg.max_videos_default;
            YT_MAX_VIDEOS_INITIAL = toString cfg.max_videos_initial;
            YT_DELETE_GRACE_PERIOD = cfg.delete_grace_period;
            YT_SLEEP_BETWEEN_CHANNELS = toString cfg.sleep_between_channels;
            # Metrics textfile directory for node_exporter
            TEXTFILE_DIRECTORY = "/var/lib/prometheus-node-exporter-text-files";
            # Make the bgutil yt-dlp plugin discoverable by yt-dlp's Python plugin scanner
            PYTHONPATH = "${bgutil-plugin}/${bgutil-plugin.pythonModule.sitePackages}";
          };

        # Add required tools to PATH
        path = with pkgs; [
          master.yt-dlp
          rsync
          coreutils # for du
        ];

        # Simple script execution - the Babashka script handles everything
        script = ''
          mkdir -p "${cfg.temp_dir}"
          exec ${pkgs.babashka-scripts}/bin/youtube-downloader
        '';
      };
      timers.yt-download-and-clean.timerConfig.RandomizedDelaySec = "15m";
    };
  };
}
