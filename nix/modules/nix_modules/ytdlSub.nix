{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.ytdlSub;

  # Normalize a channel entry to { name, shorts }
  normalizeChannel =
    ch:
    if builtins.isString ch then
      {
        name = ch;
        shorts = true;
      }
    else
      {
        name = ch.name;
        shorts = ch.shorts or true;
      };

  # Strip leading @ from handle for display name
  displayName = handle: removePrefix "@" handle;

  # Build URL from @handle
  channelUrl = handle: "https://www.youtube.com/${handle}";

  # Collect all channels across all genres, normalized
  allChannels = concatLists (
    mapAttrsToList (_genre: channels: map normalizeChannel channels) cfg.channels
  );

  # Partition into shorts-ok and no-shorts channels, grouped by genre
  buildSubscriptions =
    presetName:
    let
      filter =
        if presetName == "no_shorts" then
          (ch: !(normalizeChannel ch).shorts)
        else
          (ch: (normalizeChannel ch).shorts);
    in
    mapAttrs (
      genre: channels:
      let
        filtered = builtins.filter filter channels;
        normalized = map normalizeChannel filtered;
      in
      listToAttrs (
        map (ch: {
          name = displayName ch.name;
          value = channelUrl ch.name;
        }) normalized
      )
    ) cfg.channels;

  # Remove empty genre groups
  nonEmptySubscriptions =
    presetName: filterAttrs (_genre: channels: channels != { }) (buildSubscriptions presetName);

  hasNoShortsChannels = (nonEmptySubscriptions "no_shorts") != { };

  # Format genre keys with = prefix for ytdl-sub
  formatGenreKey = genre: "= ${genre}";
  formatSubscriptions =
    presetName:
    mapAttrs' (genre: channels: {
      name = formatGenreKey genre;
      value = channels;
    }) (nonEmptySubscriptions presetName);

  bgutil-plugin = pkgs.master.python313Packages.bgutil-ytdlp-pot-provider;
in
{
  options.systemFoundry.ytdlSub = {
    enable = mkEnableOption "ytdl-sub YouTube channel downloader";

    media_dir = mkOption {
      type = types.path;
      description = "Output directory for completed videos";
      default = "/var/lib/ytdl-sub/media";
    };

    data_dir = mkOption {
      type = types.path;
      description = "State directory for cookies, logs, and archives";
      default = "/var/lib/ytdl-sub/youtube";
    };

    temp_dir = mkOption {
      type = types.path;
      description = "Working directory for in-progress downloads";
      default = "/var/lib/ytdl-sub/tmp";
    };

    schedule = mkOption {
      type = types.str;
      description = "Systemd timer calendar expression";
      default = "*-*-* 03:00:00";
    };

    lookback_period = mkOption {
      type = types.str;
      description = "How far back to look for videos (e.g. '2weeks', '1month')";
      default = "2weeks";
    };

    channels = mkOption {
      type = types.attrsOf (types.listOf (types.either types.str types.attrs));
      description = ''
        Channels grouped by genre. Each genre becomes a Jellyfin genre tag.
        Channels can be strings ("@Handle") or attrs ({ name = "@Handle"; shorts = false; }).
      '';
      example = {
        Cycling = [
          "@BeauMiles"
          "@SethsBikeHacks"
        ];
        Entertainment = [
          "@colinfurze"
          {
            name = "@theslappablejerk";
            shorts = false;
          }
        ];
      };
    };
  };

  config = mkIf cfg.enable {

    services.ytdl-sub = {
      package = pkgs.master.ytdl-sub;
      group = "media";

      instances.youtube = {
        enable = true;
        schedule = cfg.schedule;
        readWritePaths = [
          cfg.media_dir
          cfg.temp_dir
          cfg.data_dir
        ];

        config = {
          configuration = {
            working_directory = mkForce cfg.temp_dir;
            persist_logs = {
              logs_directory = "${cfg.data_dir}/logs";
              keep_successful_logs = true;
            };
          };

          presets.base = {
            preset = [
              "Jellyfin TV Show by Date"
              "Only Recent"
            ];

            chapters.embed_chapters = true;

            subtitles = {
              embed_subtitles = true;
              languages = [ "en" ];
              allow_auto_generated_subtitles = true;
            };

            ytdl_options = {
              cookiefile = "${cfg.data_dir}/cookies.txt";
              format = "bestvideo+bestaudio/best";
            };

            overrides = {
              tv_show_directory = cfg.media_dir;
              only_recent_date_range = cfg.lookback_period;
            };
          };

          presets.no_shorts = mkIf hasNoShortsChannels {
            preset = [ "base" ];
            match_filters.filters = [
              "original_url!*=/shorts/"
              "duration>60"
            ];
          };
        };

        subscriptions = {
          base = formatSubscriptions "base";
        }
        // optionalAttrs hasNoShortsChannels { no_shorts = formatSubscriptions "no_shorts"; };
      };
    };

    # Ensure download directories exist with correct ownership
    systemd.tmpfiles.rules = [
      "d ${cfg.media_dir} 0775 ytdl-sub media -"
      "Z ${cfg.media_dir} 0775 ytdl-sub media -"
      "d ${cfg.temp_dir} 0775 ytdl-sub media -"
      "Z ${cfg.temp_dir} 0775 ytdl-sub media -"
      "d ${cfg.data_dir} 0775 ytdl-sub media -"
      "d ${cfg.data_dir}/logs 0775 ytdl-sub media -"
    ];

    # bgutil PO token provider for YouTube bot detection bypass
    systemd.services.bgutil-pot-server = {
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

    # Inject bgutil plugin and dependency ordering into the ytdl-sub service
    systemd.services.ytdl-sub-youtube = {
      wants = [ "bgutil-pot-server.service" ];
      after = [ "bgutil-pot-server.service" ];
      environment.PYTHONPATH = "${bgutil-plugin}/${bgutil-plugin.pythonModule.sitePackages}";
    };
  };
}
