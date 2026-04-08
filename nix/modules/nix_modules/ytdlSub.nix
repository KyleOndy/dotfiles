{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.ytdlSub;

  # Normalize a channel entry to { name, shorts, tier }
  normalizeChannel =
    ch:
    if builtins.isString ch then
      {
        name = ch;
        shorts = true;
        tier = "weekly";
      }
    else
      {
        name = ch.name;
        shorts = ch.shorts or true;
        tier = ch.tier or "weekly";
      };

  # Strip leading @ from handle for display name
  displayName = handle: removePrefix "@" handle;

  # Build URL from @handle
  channelUrl = handle: "https://www.youtube.com/${handle}";

  # Build subscriptions for a specific tier and preset
  buildSubscriptionsForTier =
    tierName: presetName:
    let
      shortsFilter =
        if presetName == "no_shorts" then
          (ch: !(normalizeChannel ch).shorts)
        else
          (ch: (normalizeChannel ch).shorts);
    in
    mapAttrs (
      _genre: channels:
      let
        filtered = builtins.filter (ch: (normalizeChannel ch).tier == tierName && shortsFilter ch) channels;
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
  nonEmptySubscriptionsForTier =
    tierName: presetName:
    filterAttrs (_genre: channels: channels != { }) (buildSubscriptionsForTier tierName presetName);

  hasNoShortsChannelsForTier = tierName: (nonEmptySubscriptionsForTier tierName "no_shorts") != { };

  # Format genre keys with = prefix for ytdl-sub
  formatGenreKey = genre: "= ${genre}";
  formatSubscriptionsForTier =
    tierName: presetName:
    mapAttrs' (genre: channels: {
      name = formatGenreKey genre;
      value = channels;
    }) (nonEmptySubscriptionsForTier tierName presetName);

  bgutil-plugin = pkgs.master.python313Packages.bgutil-ytdlp-pot-provider;

  # ExecStartPre script to fix .trickplay directory permissions (runs as root)
  fixTrickplayPerms = pkgs.writeShellScript "fix-trickplay-perms" ''
    find ${cfg.media_dir} -path '*.trickplay*' -type d -exec chmod g+rwX {} +
  '';
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

    max_videos = mkOption {
      type = types.int;
      description = "Default maximum number of recent videos to check per channel";
      default = 20;
    };

    tiers = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            schedule = mkOption {
              type = types.str;
              description = "Systemd timer calendar expression for this tier";
            };
            max_videos = mkOption {
              type = types.int;
              description = "Maximum videos to check per channel in this tier";
              default = 20;
            };
          };
        }
      );
      description = ''
        Download frequency tiers. Each tier generates a separate ytdl-sub instance
        with its own schedule. Channels are assigned via the `tier` attribute;
        default tier is "weekly".
      '';
      default = {
        weekly = {
          schedule = "Mon *-*-* 03:00:00";
        };
      };
    };

    source_address = mkOption {
      type = types.nullOr types.str;
      description = "Source IP for yt-dlp to bind outgoing connections to";
      default = null;
    };

    wireguard_service = mkOption {
      type = types.nullOr types.str;
      description = "Systemd service name for a WireGuard tunnel to wait for before downloading";
      default = null;
      example = "wireguard-wg-home.service";
    };

    channels = mkOption {
      type = types.attrsOf (types.listOf (types.either types.str types.attrs));
      description = ''
        Channels grouped by genre. Each genre becomes a Jellyfin genre tag.
        Channels can be strings ("@Handle") or attrs with optional fields:
          - shorts = false  (exclude YouTube Shorts)
          - tier = "daily"  (override download tier; default: "weekly")
      '';
      example = {
        Cycling = [
          "@BeauMiles"
          {
            name = "@SethsBikeHacks";
            tier = "daily";
          }
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

      instances = mapAttrs' (
        tierName: tierCfg:
        nameValuePair "youtube_${tierName}" {
          enable = true;
          schedule = tierCfg.schedule;
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
              preset = [ "Jellyfin TV Show by Date" ];

              chapters.embed_chapters = true;

              subtitles = {
                embed_subtitles = true;
                languages = [ "en" ];
                allow_auto_generated_subtitles = true;
              };

              ytdl_options = {
                cookiefile = "${cfg.data_dir}/cookies.txt";
                format = "bestvideo+bestaudio/best";
                noprogress = true;
                playlistend = tierCfg.max_videos;
                sleep_requests = 5;
                sleep_interval = 10;
                max_sleep_interval = 30;
                extractor_args = {
                  youtube = {
                    player_client = [ "web" ];
                    player_skip = [ "player_response" ];
                    fetch_pot = [ "always" ];
                  };
                };
              }
              // optionalAttrs (cfg.source_address != null) {
                source_address = cfg.source_address;
              };

              overrides = {
                tv_show_directory = cfg.media_dir;
              };
            };

            presets.no_shorts = mkIf (hasNoShortsChannelsForTier tierName) {
              preset = [ "base" ];
              match_filters.filters = [
                "original_url!*=/shorts/"
                "duration>60"
              ];
            };
          };

          subscriptions = {
            base = formatSubscriptionsForTier tierName "base";
          }
          // optionalAttrs (hasNoShortsChannelsForTier tierName) {
            no_shorts = formatSubscriptionsForTier tierName "no_shorts";
          };
        }
      ) cfg.tiers;
    };

    # Ensure download directories exist with correct ownership
    systemd.tmpfiles.rules = [
      "d ${cfg.media_dir} 0775 ytdl-sub media -"
      "d ${cfg.temp_dir} 0775 ytdl-sub media -"
      "d ${cfg.data_dir} 0775 ytdl-sub media -"
      "d ${cfg.data_dir}/logs 0775 ytdl-sub media -"
    ];

    # bgutil PO token provider + per-tier service overrides (bgutil dep, PYTHONPATH, trickplay fix)
    systemd.services = {
      bgutil-pot-server = {
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
    }
    // mapAttrs' (
      tierName: _:
      let
        wgDeps = optionalAttrs (cfg.wireguard_service != null) {
          wants = [ cfg.wireguard_service ];
          after = [ cfg.wireguard_service ];
        };
      in
      nameValuePair "ytdl-sub-youtube_${tierName}" (
        wgDeps
        // {
          wants = (wgDeps.wants or [ ]) ++ [ "bgutil-pot-server.service" ];
          after = (wgDeps.after or [ ]) ++ [ "bgutil-pot-server.service" ];
          environment = {
            PYTHONPATH = "${bgutil-plugin}/${bgutil-plugin.pythonModule.sitePackages}";
            XDG_CACHE_HOME = "/var/cache/ytdl-sub";
          };
          serviceConfig = {
            CacheDirectory = "ytdl-sub";
            # Run as root to fix .trickplay dir permissions created by Jellyfin
            ExecStartPre = "+${fixTrickplayPerms}";
          };
        }
      )
    ) cfg.tiers;
  };
}
