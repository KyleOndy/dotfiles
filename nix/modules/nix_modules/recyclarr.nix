# Sonarr and Radarr quality profiles, custom formats and size limits, synced
# from the TRaSH Guides by recyclarr. Like lidarr-settings, it runs on every
# deploy that changes it and owns what it manages outright: a UI edit to a
# managed profile is reverted on the next run. Profiles it does not name,
# which series or movie uses which profile, and Sonarr release profiles stay
# UI-owned; recyclarr cannot manage the last two at all.
{
  lib,
  pkgs,
  config,
  inputs,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.recyclarr;
  stateDir = "/var/lib/recyclarr";

  # The only TRaSH data recyclarr reads, so the guides move with flake.lock.
  settings = (pkgs.formats.yaml { }).generate "recyclarr-settings.yml" {
    resource_providers = [
      {
        name = "trash-guides-pinned";
        type = "trash-guides";
        path = "${inputs.trash-guides}";
        replace_default = true;
      }
    ];
  };

  # TRaSH scores every unwanted format -10000. Above this, a release with any
  # one of them stays rejected even with every positive score stacked (about
  # +3600), while the soft -500 penalties below still pass together.
  minFormatScore = -5000;

  # Discouraged, not blocked. LQ lists MarkII, Mesc and YIFY, often the only
  # usenet copy of an old special, Line/Mic Dubbed would reject most cams, and
  # a German DL release still carries the original-language track.
  softPenalty = -500;

  # A quality name, or a group of them. Order is preference, best first.
  q = name: { inherit name; };
  off = name: {
    inherit name;
    enabled = false;
  };
  group = name: qualities: { inherit name qualities; };

  groupsFor =
    profiles:
    map (trash_id: {
      inherit trash_id;
      assign_scores_to = profiles;
    });
in
{
  options.systemFoundry.recyclarr = {
    enable = mkEnableOption "recyclarr-managed Sonarr and Radarr quality settings";

    sonarr = {
      url = mkOption {
        type = types.str;
        default = "http://127.0.0.1:8989";
      };
      apiKeyFile = mkOption { type = types.path; };
    };

    radarr = {
      url = mkOption {
        type = types.str;
        default = "http://127.0.0.1:7878";
      };
      apiKeyFile = mkOption { type = types.path; };
    };
  };

  config = mkIf cfg.enable {
    services.recyclarr = {
      enable = true;
      configuration = {
        radarr.radarr = {
          base_url = cfg.radarr.url;
          api_key._secret = cfg.radarr.apiKeyFile;
          delete_old_custom_formats = true;

          # Sizes are MB per minute. TRaSH's Bluray minimums reject the small
          # x265 encodes most old specials exist as (Rudolph 1964 at 2160p is
          # 55 against a minimum of 102), so Bluray takes the WEB minimum of the
          # same resolution. A 0.5 GB "2160p" half-hour special is still
          # rejected.
          quality_definition = {
            type = "movie";
            qualities = [
              {
                name = "Bluray-2160p";
                min = 34.5;
              }
              {
                name = "HDTV-2160p";
                min = 34.5;
              }
              {
                name = "Bluray-1080p";
                min = 12.5;
              }
              {
                name = "HDTV-1080p";
                min = 12.5;
              }
              {
                name = "Bluray-720p";
                min = 12.5;
              }
            ];
          };

          # Not guide-backed: a guide profile forces the language to Original,
          # and this one keeps English.
          quality_profiles = [
            {
              name = "Up to 4K";
              reset_unmatched_scores.enabled = true;
              upgrade = {
                allowed = true;
                until_quality = "Bluray-2160p";
                until_score = 10000;
              };
              min_format_score = minFormatScore;
              # Disabled qualities still rank for the cutoff: Remux-1080p sits
              # above Bluray-1080p so an existing remux upgrades to 2160p
              # rather than downgrading. Cams are allowed last, so any real
              # release replaces one.
              qualities = [
                (off "Remux-2160p")
                (q "Bluray-2160p")
                (group "WEB 2160p" [
                  "WEBDL-2160p"
                  "WEBRip-2160p"
                ])
                (q "HDTV-2160p")
                (off "Remux-1080p")
                (q "Bluray-1080p")
                (group "WEB 1080p" [
                  "WEBDL-1080p"
                  "WEBRip-1080p"
                ])
                (q "HDTV-1080p")
                (q "Bluray-720p")
                (group "WEB 720p" [
                  "WEBDL-720p"
                  "WEBRip-720p"
                ])
                (q "HDTV-720p")
                (q "Bluray-576p")
                (q "Bluray-480p")
                (group "WEB 480p" [
                  "WEBDL-480p"
                  "WEBRip-480p"
                ])
                (q "DVD-R")
                (q "DVD")
                (q "SDTV")
                (q "DVDSCR")
                (q "REGIONAL")
                (q "TELECINE")
                (q "TELESYNC")
                (q "CAM")
                (q "WORKPRINT")
                (off "BR-DISK")
                (off "Raw-HD")
                (off "Unknown")
              ];
            }
          ];

          custom_format_groups.add =
            let
              profiles = [ { name = "Up to 4K"; } ];
            in
            [
              {
                trash_id = "a3ac6af01d78e4f21fcb75f601ac96df"; # [Unwanted] Unwanted Formats
                assign_scores_to = profiles;
                exclude = [
                  # Both Ultra and Firefox direct-play AV1.
                  "cae4ca30163749b891686f95532519bd" # AV1
                  # The tagged release of a colorized classic is the original.
                  "cc444569854e9de0b084ab2b8b1532b2" # Black and White Editions
                  # The library holds Disney Sing-Along Songs on purpose.
                  "712d74cd88bceb883ee32f773656b1f5" # Sing-Along Versions
                  # Scored softly below instead.
                  "90a6f9a284dff5103f6346090e6280c8" # LQ
                  "e204b80c87be9497a8a6eaff48f72905" # LQ (Release Title)
                  "c465ccc73923871b3eb1802042331306" # Line/Mic Dubbed
                ];
              }
              {
                trash_id = "d688ff99733a9bc626c37eb61ea74704"; # [Required] Repack/Proper
                assign_scores_to = profiles;
              }
              {
                trash_id = "b2f2af430f73f3ad1f9948f33e0f0cf8"; # [Release Groups] HQ
                assign_scores_to = profiles;
                select_all = true;
              }
              {
                trash_id = "d9cc9a504e5ede6294c8b973aad4f028"; # [Streaming Services] General
                assign_scores_to = profiles;
              }
            ]
            # DV without an HDR10 fallback plays only on the Ultra without a
            # tonemapping transcode.
            # No SDR format: it reads SDR from a missing HDR tag, and the
            # untagged UHD Blurays here from MALUS, WhiteRhino and MiMiC are
            # HDR10 or DV7.
            ++ groupsFor profiles [
              "ef20e67b95a381fb3bc6d1f06ea24f46" # HDR
              "1616617ab3a14397a2b2321bcbda44d1" # DV Boost
              "b29413a7487478fe98228ce79e5689e4" # HDR10+ Boost
              "7fc2751eef7e6bdc70b74136e5e35c76" # DV (w/o HDR fallback)
            ];

          custom_formats = [
            {
              trash_ids = [
                "90a6f9a284dff5103f6346090e6280c8" # LQ
                "e204b80c87be9497a8a6eaff48f72905" # LQ (Release Title)
                "c465ccc73923871b3eb1802042331306" # Line/Mic Dubbed
                "f845be10da4f442654c13e1f2c3d6cd5" # German DL
              ];
              assign_scores_to = [
                {
                  name = "Up to 4K";
                  score = softPenalty;
                }
              ];
            }
          ];
        };

        sonarr.sonarr = {
          base_url = cfg.sonarr.url;
          api_key._secret = cfg.sonarr.apiKeyFile;
          delete_old_custom_formats = true;

          # Same reasoning as Radarr's sizes, per episode minute.
          quality_definition = {
            type = "series";
            qualities = [
              {
                name = "Bluray-2160p";
                min = 25;
              }
              {
                name = "Bluray-1080p";
                min = 15;
              }
              {
                name = "Bluray-720p";
                min = 10;
              }
            ];
          };

          quality_profiles = [
            {
              name = "Up to 4K";
              reset_unmatched_scores.enabled = true;
              # The cutoff stays at WEB 2160p: a Bluray-2160p grab is taken
              # when it is there, but never re-downloads a whole season.
              upgrade = {
                allowed = true;
                until_quality = "WEB 2160p";
                until_score = 10000;
              };
              min_format_score = minFormatScore;
              qualities = [
                (off "Bluray-2160p Remux")
                (q "Bluray-2160p")
                (group "WEB 2160p" [
                  "WEBDL-2160p"
                  "WEBRip-2160p"
                ])
                (q "HDTV-2160p")
                (off "Bluray-1080p Remux")
                (q "Bluray-1080p")
                (group "WEB 1080p" [
                  "WEBDL-1080p"
                  "WEBRip-1080p"
                ])
                (q "HDTV-1080p")
                (q "Bluray-720p")
                (group "WEB 720p" [
                  "WEBDL-720p"
                  "WEBRip-720p"
                ])
                (q "HDTV-720p")
                (q "Bluray-576p")
                (q "Bluray-480p")
                (q "DVD")
                (group "WEB 480p" [
                  "WEBDL-480p"
                  "WEBRip-480p"
                ])
                (q "SDTV")
                (off "Raw-HD")
                (off "Unknown")
              ];
            }
          ];

          custom_format_groups.add =
            let
              profiles = [ { name = "Up to 4K"; } ];
            in
            [
              {
                # Sonarr's Upscaled only matches a tag after the resolution,
                # so "S01E01.Ai.Upscale.2160p" gets through.
                trash_id = "59c3af66780d08332fdc64e68297098f"; # [Unwanted] Unwanted Formats
                assign_scores_to = profiles;
                exclude = [
                  "15a05bc7c1a36e2b57fd628f8977e2fc" # AV1
                  "9c11cd3f07101cdba90a2d81cf0e56b4" # LQ
                  "e2315f990da2e2cbfc9fa5b7a6fcfe48" # LQ (Release Title)
                ];
              }
              {
                trash_id = "22256473b656e195eabc2798e326fbb7"; # [Required] Repack/Proper
                assign_scores_to = profiles;
              }
              {
                trash_id = "b4a4353e3b3e6789dbef07677ff23686"; # [Release Groups] HQ
                assign_scores_to = profiles;
                select_all = true;
              }
              {
                trash_id = "abe720fab2d27682adc2a735136cec02"; # [Streaming Services] General
                assign_scores_to = profiles;
              }
              {
                trash_id = "85fae4a2294965b75710ef2989c850eb"; # [Streaming Services] HD/UHD boost
                assign_scores_to = profiles;
              }
            ]
            ++ groupsFor profiles [
              "7e1724c5da59e7474803ad25be98f6a3" # HDR
              "e0b2774083df4265f25c9e5bc6c80940" # DV Boost
              "7d366c213e5c23a052b157356fac1921" # HDR10+ Boost
              "d776a1ea912a117d66d83b880ff2055d" # DV (w/o HDR fallback)
            ];

          custom_formats = [
            {
              trash_ids = [
                "9c11cd3f07101cdba90a2d81cf0e56b4" # LQ
                "e2315f990da2e2cbfc9fa5b7a6fcfe48" # LQ (Release Title)
                "ed51973a811f51985f14e2f6f290e47a" # German DL
              ];
              assign_scores_to = [
                {
                  name = "Up to 4K";
                  score = softPenalty;
                }
              ];
            }
          ];
        };
      };
    };

    systemd.services.recyclarr = {
      after = [
        "sonarr.service"
        "radarr.service"
      ];
      wants = [
        "sonarr.service"
        "radarr.service"
      ];
      wantedBy = [ "multi-user.target" ];
      preStart = mkAfter ''
        ln -sfn ${settings} ${stateDir}/settings.yml

        # A switch that restarts Sonarr or Radarr starts this unit in the same
        # second, before either answers, and a failed start fails the switch.
        for url in ${cfg.sonarr.url} ${cfg.radarr.url}; do
          for _ in $(seq 60); do
            ${pkgs.curl}/bin/curl -sf --max-time 5 "$url/ping" >/dev/null && break
            sleep 2
          done
        done
      '';
      serviceConfig = {
        # Active after a run, so switch-to-configuration reruns it when the
        # config changes and leaves it alone when it does not.
        RemainAfterExit = true;
        # The rendered config.yml holds both API keys in plain text.
        UMask = "0077";
        StateDirectoryMode = "0700";
      };
    };

    # A timer could never fire it again: starting an active unit is a no-op.
    systemd.timers.recyclarr.enable = false;
  };
}
