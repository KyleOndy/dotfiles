{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [ ./hardware-configuration.nix ];

  networking = {
    hostName = "elk";
    # Required for mdadm - derived from /etc/machine-id
    hostId = "a7f3b1d2";

    firewall = {
      # No WireGuard - all services are local
      allowedTCPPorts = [
        80
        443
      ];
    };
  };

  time.timeZone = "America/New_York";
  i18n = {
    defaultLocale = "en_US.UTF-8";
    extraLocaleSettings = {
      LC_ALL = "en_US.UTF-8";
    };
  };

  # Boot loader configuration - GRUB with EFI support
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    devices = [ "nodev" ];
  };
  boot.loader.efi.canTouchEfiVariables = false;

  boot.binfmt.emulatedSystems = [
    "aarch64-linux"
  ];

  # Enable mdadm for RAID1 (2x NVMe in software RAID)
  boot.swraid.enable = true;
  boot.swraid.mdadmConf = ''
    PROGRAM /etc/mdadm-alert.sh
    MAILADDR root
  '';

  # mdadm event logging to journald (picked up by promtail)
  environment.etc."mdadm-alert.sh" = {
    mode = "0755";
    text = ''
      #!${pkgs.bash}/bin/bash
      ${pkgs.util-linux}/bin/logger -t mdadm -p daemon.warning "RAID event: $1 on device $2 component $3"
    '';
  };

  # Intel iGPU hardware transcoding (i5-13500, UHD 770)
  # https://nixos.wiki/wiki/Accelerated_Video_Playback
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      vpl-gpu-rt # Intel VPL — native 12th/13th gen (Alder/Raptor Lake)
      intel-media-driver # VA-API iHD driver
      libvdpau-va-gl # VDPAU compatibility
      intel-compute-runtime # OpenCL for HDR tonemapping and subtitle burn-in
      ocl-icd # OpenCL ICD loader
    ];
  };
  environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

  # Expose OpenCL ICD file for Jellyfin HDR tonemapping
  environment.etc."OpenCL/vendors/intel-neo.icd".source =
    "${pkgs.intel-compute-runtime}/etc/OpenCL/vendors/intel-neo.icd";

  # Allow svc.deploy to write to website directory
  users.users."svc.deploy".extraGroups = [ "nginx" ];

  # Allow kyle to access Tdarr API key and media files
  users.users.kyle.extraGroups = [ "media" ];

  # Create media group for shared access to downloads/media
  users.groups.media = {
    gid = 983;
  };

  # Jellyfin user permissions for media access and hardware transcoding
  users.users.jellyfin.extraGroups = [
    "media"
    "render" # Intel GPU access for VA-API transcoding
    "video" # Intel GPU access for VA-API transcoding
  ];
  systemd.services.jellyfin.serviceConfig.SupplementaryGroups = [
    "media"
    "render"
    "video"
  ];

  # System packages
  environment.systemPackages = with pkgs; [
    intel-gpu-tools # intel_gpu_top for monitoring GPU usage
    (pkgs.writeShellScriptBin "tdarr-failure-summary" ''
      export PATH="${
        lib.makeBinPath [
          pkgs.curl
          pkgs.jq
          pkgs.coreutils
        ]
      }"
      export TDARR_API_KEY_FILE="${config.sops.secrets.tdarr_api_key.path}"
      exec ${pkgs.bash}/bin/bash ${./tdarr-failure-summary.sh} "$@"
    '')
  ];

  # Ensure directories exist with proper permissions
  systemd.tmpfiles.rules = [
    # Website directory - 0775 allows nginx group members (including svc.deploy) to write
    "d /var/www/kyleondy.com 0775 nginx nginx -"
    # Download directories - 0775 allows media group members to read/write
    "d /mnt/storage/downloads 0755 root root -"
    "d /mnt/storage/downloads/complete 0775 root media -"
    "d /mnt/storage/downloads/incomplete 0775 root media -"
    # Download category directories (match SABnzbd categories)
    "d /mnt/storage/downloads/complete/movies 0775 root media -"
    "d /mnt/storage/downloads/complete/tv 0775 root media -"
    "d /mnt/storage/downloads/complete/music 0775 root media -"
    "d /mnt/storage/downloads/complete/books 0775 root media -"
    # Media directories - 0775 allows media group members to read/write
    "d /mnt/storage/media 0775 root media -"
    "d /mnt/storage/media/movies 0775 root media -"
    "d /mnt/storage/media/tv 0775 root media -"
    "d /mnt/storage/media/music 0775 root media -"
    "d /mnt/storage/media/books 0775 root media -"
    # Staging area for files not indexed by Jellyfin
    # setgid (2775) so subdirs inherit the media group automatically
    "d /mnt/storage/media/tmp 2775 root media -"
  ];

  systemFoundry = {
    # Enable Docker for OCI containers
    docker.enable = true;

    nginxReverseProxy = {
      acme = {
        email = "kyle@ondy.org";
        dnsProvider = "route53";
        credentialsSecret = "apps_ondy_org_route53";
      };

      sites = {
        # Main website
        "www.kyleondy.com" = {
          enable = true;
          provisionCert = true;
          staticRoot = "/var/www/kyleondy.com";
          route53HostedZoneId = "Z0855021CRZ8TKMBC7EC";
        };

        # Redirect apex domain to www
        "kyleondy.com" = {
          enable = true;
          provisionCert = true;
          redirectTo = "www.kyleondy.com";
          route53HostedZoneId = "Z0855021CRZ8TKMBC7EC";
        };

        # Redirect ondy.org to www.kyleondy.com
        "ondy.org" = {
          enable = true;
          provisionCert = true;
          redirectTo = "www.kyleondy.com";
        };

        # Default catch-all server that redirects to www.kyleondy.com
        "_" = {
          enable = true;
          isDefault = true;
          extraDomainNames = [ "www.kyleondy.com" ];
        };
      };
    };

    # VictoriaMetrics-based monitoring stack
    monitoringStack = {
      enable = true;
      domain = "apps.ondy.org";

      # Retention configuration
      retention = {
        metrics = 400; # days
        logs = 400; # days
      };

      # Server-side components (central monitoring server)
      victoriametrics = {
        enable = true;
        provisionCert = true;
        domain = "metrics.apps.ondy.org";
      };

      loki = {
        enable = true;
        provisionCert = true;
        domain = "loki.apps.ondy.org";
        instanceInterfaceNames = [
          "enp5s0"
          "lo"
        ];
      };

      grafana = {
        enable = true;
        provisionCert = true;
        domain = "grafana.apps.ondy.org";
      };

      alertmanager = {
        enable = true;
      };

      vmalert = {
        enable = true;
        provisionCert = true;
        domain = "vmalert.apps.ondy.org";
      };

      # Local monitoring agents (elk monitors itself)
      nodeExporter = {
        enable = true;
      };

      nginxExporter = {
        enable = true;
      };

      nginxlogExporter = {
        enable = true;
      };

      jellyfinExporter = {
        enable = true;
        jellyfinUrl = "http://127.0.0.1:8096";
        apiKeyFile = config.sops.secrets.jellyfin_api_key.path;
        enableActivityCollector = true;
      };

      jellyfinPlaycount = {
        enable = false;
        jellyfinUrl = "http://127.0.0.1:8096";
        apiKeyFile = config.sops.secrets.jellyfin_api_key.path;
        monitorAllUsers = true;
      };

      # Exportarr for *arr services metrics
      exportarr = {
        enable = true;

        sonarr = {
          enable = false;
          apiKeyFile = config.sops.secrets.sonarr_api_key.path;
        };

        radarr = {
          enable = false;
          apiKeyFile = config.sops.secrets.radarr_api_key.path;
        };

        lidarr = {
          enable = false;
          apiKeyFile = config.sops.secrets.lidarr_api_key.path;
        };

        readarr = {
          enable = false;
          apiKeyFile = config.sops.secrets.readarr_api_key.path;
        };

        prowlarr = {
          enable = false;
          apiKeyFile = config.sops.secrets.prowlarr_api_key.path;
        };

        bazarr = {
          enable = false;
          apiKeyFile = config.sops.secrets.bazarr_api_key.path;
        };

        sabnzbd = {
          enable = false;
          apiKeyFile = config.sops.secrets.sabnzbd_api_key.path;
        };
      };

      # Tdarr metrics exporter
      tdarrExporter = {
        enable = true;
        tdarrUrl = "http://127.0.0.1:8265";
        apiKeyFile = config.sops.secrets.tdarr_api_key.path;
      };

      vmagent = {
        enable = true;
        # Send metrics to local VictoriaMetrics instance
        remoteWriteUrl = "http://127.0.0.1:8428/api/v1/write";
        # Scrape local exporters
        scrapeConfigs = [
          {
            job_name = "node";
            static_configs = [
              {
                targets = [ "127.0.0.1:9100" ];
                labels = {
                  host = "elk";
                };
              }
            ];
          }
          {
            job_name = "nginx";
            static_configs = [
              {
                targets = [ "127.0.0.1:9113" ];
                labels = {
                  host = "elk";
                };
              }
            ];
          }
          {
            job_name = "nginxlog";
            static_configs = [
              {
                targets = [ "127.0.0.1:4040" ];
                labels = {
                  host = "elk";
                };
              }
            ];
          }
          {
            job_name = "tdarr";
            static_configs = [
              {
                targets = [ "127.0.0.1:9595" ];
                labels = {
                  host = "elk";
                  service = "tdarr";
                };
              }
            ];
          }
          {
            job_name = "jellyfin-exporter";
            static_configs = [
              {
                targets = [ "127.0.0.1:9594" ];
                labels = {
                  host = "elk";
                };
              }
            ];
          }
        ];
      };

      promtail = {
        enable = true;
        # Send logs to local Loki instance
        lokiUrl = "http://127.0.0.1:3100/loki/api/v1/push";
        extraLabels = {
          host = "elk";
        };
        extraScrapeConfigs = [
          {
            job_name = "jellyfin";
            static_configs = [
              {
                targets = [ "localhost" ];
                labels = {
                  job = "jellyfin";
                  host = "elk";
                  __path__ = "/var/lib/jellyfin/log/*.log";
                };
              }
            ];
          }
        ];
      };
    };

    prowlarr = {
      enable = false;
      group = "media";
      domainName = "prowlarr.apps.ondy.org";
      provisionCert = true;
    };

    sabnzbd = {
      enable = false;
      group = "media";
      domainName = "sabnzbd.apps.ondy.org";
      provisionCert = true;
    };

    bazarr = {
      enable = false;
      group = "media";
      domainName = "bazarr.apps.ondy.org";
      provisionCert = true;
    };

    lidarr = {
      enable = false;
      group = "media";
      domainName = "lidarr.apps.ondy.org";
      provisionCert = true;
    };

    radarr = {
      enable = false;
      group = "media";
      domainName = "radarr.apps.ondy.org";
      provisionCert = true;
    };

    readarr = {
      enable = false;
      group = "media";
      domainName = "readarr.apps.ondy.org";
      provisionCert = true;
    };

    sonarr = {
      enable = false;
      group = "media";
      domainName = "sonarr.apps.ondy.org";
      provisionCert = true;
    };

    # Jellyfin media server with QuickSync transcoding (local media at /mnt/storage/media)
    jellyfin = {
      enable = true;
      group = "media";
      domainName = "jellyfin.apps.ondy.org";
      provisionCert = true;
      transcodeCleanupInterval = "36 hours";
      debugAuthLogging = true;
      transcodeDebugLogging = true;
      installPlaybackReportingPlugin = true;
    };

    jellyseerr = {
      enable = true;
      domainName = "jellyseerr.apps.ondy.org";
      provisionCert = true;
    };

    # Tdarr server for media transcoding
    tdarr.server = {
      enable = true;
      mediaPath = "/mnt/storage/media";
      domainName = "tdarr.apps.ondy.org";
      provisionCert = true;
      seededApiKeyFile = config.sops.secrets.tdarr_api_key.path;

      # Flow management - import H.264 compatibility flow and assign to libraries
      flows = [
        {
          name = "H.264 Compatibility Flow";
          file = ./tdarr-compatibility-flow.json;
        }
      ];
      libraryFlowAssignments = {
        "TV" = "nixos-h264-compat";
        "Movies" = "nixos-h264-compat";
      };
    };

    # Tdarr node - local, single combined node (no path translators needed)
    tdarr.node = {
      enable = true;
      serverUrl = "http://127.0.0.1:8266";
      mediaPath = "/mnt/storage/media";
      nodeName = "elk";
      gpuWorkers = 1;
      cpuWorkers = 4; # More CPU workers since only node
      enableGpu = true;
      # No pathTranslators — media is local
      apiKeyFile = config.sops.secrets.tdarr_api_key.path;
    };
  };

  # Subtitle extractor - scans media library hourly for missing subtitle sidecars
  systemFoundry.subtitleExtractor = {
    enable = true;
    mediaPath = "/mnt/storage/media";
    schedule = "hourly";
    user = "root";
    group = "root";
  };

  # YouTube downloader - downloads videos from subscribed channels
  systemFoundry.youtubeDownloader = {
    enable = false;
    media_dir = "/mnt/storage/media/yt";
    temp_dir = "/mnt/storage/downloads/youtube-temp";
    sleep_between_channels = 180;
    max_videos_default = 5;
    max_videos_initial = 30;
    download_shorts = true;

    watched_channels = [
      # cycling
      "@BeauMiles"
      "@BermPeakExpress"
      "@bike2reality814"
      "@BIKEPACKINGcom"
      "@BikePak"
      "@chadweberg1" # Chad Weberg
      "@ChumbaUSABikes"
      "@Cycling366"
      "@Danny_MacAskill"
      "@DirtyTeethMTB"
      "@duzer"
      "@DylanJohnsonCycling"
      "@EFProCycling"
      "@FarBeyond-EFPC"
      "@FullBeansCyclingCompany"
      "@hennapalosaari_"
      "@howtheracewaswon"
      "@JackScottkeogh"
      "@jasperverkuijl"
      "@jjjjustin"
      "@joe.nation"
      "@joffreymaluski"
      "@joshibbett"
      "@justinasleveika"
      "@katrinahase"
      "@KDubzDidWhat"
      "@KeepSmilingAdventures"
      "@lesperitdelbikepacking"
      "@MediocreAmateur"
      "@MickTurnbullFilms"
      "@msoleilblais74"
      "@omniumcargo"
      "@panoramacycles"
      "@PatrickMcGrady1"
      "@PaulComponentEngineering"
      "@pnwbikepacking"
      "@raphafilms"
      "@RideProductionsNZ"
      "@RousLigon"
      "@SethsBikeHacks"
      "@sofianeshl"
      "@sportscientist" # Stephen Seiler
      "@stephanwieser"
      "@TailfinCycling"
      "@TENTISTHENEWRENT"
      "@the_dirtbags"
      "@themountainraces"
      "@TheVCAdventures" # The Vegan Cyclist
      "@tristanbogaard"
      "@tristantakevideo"
      "@TurnCycling"
      "@ValleyPreferredCyclingCenter"
      "@wattwagon"
      "@wheelstowaves"
      "@worstretirementever" # Phil Gaimon

      # science
      "@AlphaPhoenixChannel"
      "@BetaPhoenixChannel"
      "@miniminuteman773"

      # maker
      "@aaedmusa"
      "@BennettStirton"
      "@dkbuilds"
      "@lostartpress"
      "@MarkRober"
      "@matthiaswandel"
      "@Paul.Sellers"
      "@propdepartment"
      "@RexKrueger"
      "@StuffMadeHere"
      "@StuffMadeHere2"
      "@tested"
      "@theslowmoguys"
      "@TomStantonEngineering"
      "@WoodByWrightHowTo"

      # entertainment
      "@2MuchColinFurze"
      "@Ben_Brainard"
      "@CaptainDisillusion"
      "@CharlieBerens"
      "@colinfurze"
      "@DudeDad"
      "@Gossip.Goblin"
      "@GxAce"
      "@kaptainkristian"
      "@kurzgesagt"
      "@PracticalEngineeringChannel"
      "@RudyAyoub"
      "@SampsonBoatCo"
      {
        name = "@theslappablejerk";
        download_shorts = false;
      }
      "@treykennedy"
      "@whistlindiesel"

      # tech
      "@AdamJames-tv"
      "@KRAZAM"
      "@programmersarealsohuman5909" # Kai Lentit

      # outdoor
      "@bronandjacob"
      "@ChrisburkardStudio"
      "@courtneyevewhite"
      "@RabEquipment"
      "@theaudaciousreport"
    ];
  };

  # Jellyfin prune - deletes watched YouTube videos from disk after 2 days
  # Jellyfin and media are both local on elk — no path translation needed.
  # TODO: Before deploying, update userId and parentId by querying elk's Jellyfin:
  #   curl -s 'https://jellyfin.apps.ondy.org/Users' \
  #     -H 'Authorization: MediaBrowser Token="<api_key>"' | jq '.[] | {Name, Id}'
  #   curl -s 'https://jellyfin.apps.ondy.org/Library/VirtualFolders' \
  #     -H 'Authorization: MediaBrowser Token="<api_key>"' | jq '.[] | {Name, ItemId}'
  systemd.services.jellyfin-prune = {
    enable = false;
    startAt = "*-*-* 06:00:00"; # 6am
    path = with pkgs; [
      bashInteractive
      curl
      fd
      jq
    ];
    environment = {
      TOKEN_FILE = config.sops.secrets.jellyfin_api_key.path;
      DATA_DIR = config.systemFoundry.youtubeDownloader.data_dir;
    };
    script = ''
      #!/usr/bin/env bash
      set -euo pipefail

      TOKEN=$(cat $TOKEN_FILE)
      TODAY="$(date +%Y-%m-%d)"
      TWO_DAYS_AGO="$(date -d "$TODAY - 2 days" +%Y-%m-%d)"
      WORKING_DIR="$DATA_DIR/yt-jelly-sync"
      echo "TODAY: $TODAY"
      echo "TWO_DAYS_AGO: $TWO_DAYS_AGO"
      echo "WORKING_DIR: $WORKING_DIR"

      print_watched_vids() {
        curl -sS -X 'GET' \
          'https://jellyfin.apps.ondy.org/Items?userId=04156d27514048bdbe6fc0adb8c28499&recursive=true&parentId=e59b37148e0ff06f0d35b0c3c714e75c&fields=Path&enableUserData=true&enableTotalRecordCount=false&enableImages=false' \
          -H 'accept: application/json' \
          -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | jq -r '.Items[] | select(.UserData.PlayCount >= 1) | .Path'
      }

      update_lib() {
        curl -Ss -X 'POST' \
          'https://jellyfin.apps.ondy.org/ScheduledTasks/Running/7738148ffcd07979c7ceb148e06b3aed' \
          -H 'accept: */*' \
          -H "Authorization: MediaBrowser Token=\"$TOKEN\"" \
          -d ""
      }

      main() {
        vids=$(print_watched_vids)

        [[ -d "$WORKING_DIR" ]] || mkdir "$WORKING_DIR"
        echo "$vids" | sort > "$WORKING_DIR/$TODAY.txt"

        temp_file=$(mktemp)
        fd --type=f --changed-before "$TWO_DAYS_AGO" . "$WORKING_DIR" -0 | xargs -0 -r ls -t1d > "$temp_file" 2>/dev/null || true
        old_vids_file=$(head -n1 "$temp_file" 2>/dev/null || true)
        rm -f "$temp_file"
        if ! [[ -f "$old_vids_file" ]]; then
          echo "Can not find an old enough file. We'll try again tomorrow."
          exit 0
        fi

        vids_to_remove=$(comm -12 "$WORKING_DIR/$TODAY.txt" "$old_vids_file")

        if [[ -z "$vids_to_remove" ]]; then
          echo "No videos to remove"
          exit 0
        fi

        echo "$vids_to_remove" | while read -r vid; do
          if [[ -f "$vid" ]]; then
            rm -v "$vid"
          else
            echo "Can not find $vid"
          fi
        done

        fd --type=directory --type=empty . /mnt/storage/media/yt -X rmdir -v
        echo "Updating library"
        update_lib
      }

      main
    '';
  };

  systemd.timers.jellyfin-prune.timerConfig.RandomizedDelaySec = "15m";

  # Tdarr notification script for Sonarr/Radarr integration
  environment.etc."scripts/tdarr-notify.sh" = {
    mode = "0755";
    text = ''
      #!${pkgs.bash}/bin/bash
      set -eo pipefail

      TDARR_URL="http://127.0.0.1:8265"
      TDARR_API_KEY="$(cat ${config.sops.secrets.tdarr_api_key.path})"

      TV_LIBRARY_ID="Q_Q4-iQT7"
      MOVIES_LIBRARY_ID="5sRp_iSwq"

      FILE_PATH="''${sonarr_episodefile_path:-}"
      if [[ -z "$FILE_PATH" ]]; then
        FILE_PATH="''${radarr_moviefile_path:-}"
      fi

      if [[ -z "$FILE_PATH" ]]; then
        echo "No file path provided"
        exit 0
      fi

      if [[ "$FILE_PATH" == */tv/* ]]; then
        LIBRARY_ID="$TV_LIBRARY_ID"
      else
        LIBRARY_ID="$MOVIES_LIBRARY_ID"
      fi

      if [[ -z "$LIBRARY_ID" ]]; then
        echo "No library ID configured for path: $FILE_PATH"
        exit 0
      fi

      ${pkgs.curl}/bin/curl -s -X POST "''${TDARR_URL}/api/v2/scan-files" \
        -H "Content-Type: application/json" \
        -H "x-api-key: ''${TDARR_API_KEY}" \
        -d "{\"data\":{\"scanConfig\":{\"dbID\":\"''${LIBRARY_ID}\",\"arrayOrPath\":[\"''${FILE_PATH}\"],\"mode\":\"scanFolderWatcher\"}}}"
    '';
  };

  # Subtitle extraction script for Sonarr/Radarr integration
  environment.etc."scripts/subtitle-extract-notify.sh" = {
    mode = "0755";
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      export PATH="${
        lib.makeBinPath [
          pkgs.ffmpeg-headless
          pkgs.jq
          pkgs.coreutils
          pkgs.gnugrep
        ]
      }"

      FILE_PATH="''${sonarr_episodefile_path:-}"
      if [[ -z "$FILE_PATH" ]]; then
        FILE_PATH="''${radarr_moviefile_path:-}"
      fi

      if [[ -z "$FILE_PATH" ]]; then
        echo "No file path provided by Sonarr/Radarr"
        exit 0
      fi

      if [[ "$FILE_PATH" != *.mkv ]]; then
        echo "Skipping non-MKV file: $FILE_PATH"
        exit 0
      fi

      echo "Extracting subtitles from: $FILE_PATH"

      BASE_DIR=$(dirname "$FILE_PATH")
      BASE_NAME=$(basename "$FILE_PATH" .mkv)
      BASE_PATH="$BASE_DIR/$BASE_NAME"

      SUBTITLE_STREAMS=$(${pkgs.ffmpeg-headless}/bin/ffprobe -v error -select_streams s \
        -show_entries stream=index,codec_name:stream_tags=language,title \
        -of json "$FILE_PATH" 2>/dev/null || echo '{"streams":[]}')

      TEXT_SUBS=$(echo "$SUBTITLE_STREAMS" | ${pkgs.jq}/bin/jq -r '
        .streams[] |
        select(.codec_name == "subrip" or .codec_name == "ass" or .codec_name == "mov_text" or .codec_name == "srt") |
        "\(.index)|\(.tags.language // "und")|\(.tags.title // "")"
      ')

      if [[ -z "$TEXT_SUBS" ]]; then
        echo "No text-based subtitles found in $FILE_PATH"
        exit 0
      fi

      declare -A LANG_COUNTS

      echo "$TEXT_SUBS" | while IFS='|' read -r STREAM_IDX LANG TITLE; do
        case "$LANG" in
          eng) LANG="en" ;;
          spa) LANG="es" ;;
          fre|fra) LANG="fr" ;;
          ger|deu) LANG="de" ;;
          ita) LANG="it" ;;
          por) LANG="pt" ;;
          jpn) LANG="ja" ;;
          kor) LANG="ko" ;;
          chi|zho) LANG="zh" ;;
          rus) LANG="ru" ;;
          und) LANG="und" ;;
        esac

        SUFFIX=""
        if echo "$TITLE" | ${pkgs.gnugrep}/bin/grep -iq "sdh"; then
          SUFFIX=".sdh"
        elif echo "$TITLE" | ${pkgs.gnugrep}/bin/grep -iq "forced"; then
          SUFFIX=".forced"
        elif echo "$TITLE" | ${pkgs.gnugrep}/bin/grep -iq "cc\|closed.caption"; then
          SUFFIX=".cc"
        fi

        COUNT=''${LANG_COUNTS[$LANG]:-0}
        LANG_COUNTS[$LANG]=$((COUNT + 1))
        if [[ $COUNT -gt 0 ]]; then
          SUFFIX="$SUFFIX.$COUNT"
        fi

        OUTPUT_FILE="''${BASE_PATH}.''${LANG}''${SUFFIX}.srt"

        if [[ -f "$OUTPUT_FILE" ]]; then
          echo "Sidecar already exists: $OUTPUT_FILE"
          continue
        fi

        if ${pkgs.ffmpeg-headless}/bin/ffmpeg -v error -i "$FILE_PATH" \
            -map "0:$STREAM_IDX" -c:s srt "$OUTPUT_FILE" 2>/dev/null; then
          echo "Extracted: $OUTPUT_FILE (stream $STREAM_IDX: $LANG''${TITLE:+ - $TITLE})"
        else
          echo "Failed to extract stream $STREAM_IDX from $FILE_PATH" >&2
        fi
      done
    '';
  };

  # Systemd service and timer for daily Tdarr failure report
  systemd.services.tdarr-failure-report = {
    description = "Tdarr Daily Failure Summary";
    after = [ "podman-tdarr-server.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "tdarr-failure-report-wrapper" ''
        export TDARR_API_KEY_FILE="${config.sops.secrets.tdarr_api_key.path}"
        export PATH="${
          lib.makeBinPath [
            pkgs.curl
            pkgs.jq
            pkgs.coreutils
          ]
        }"
        ${pkgs.bash}/bin/bash ${./tdarr-failure-summary.sh} 1
      ''}";
    };
  };

  systemd.timers.tdarr-failure-report = {
    description = "Timer for Tdarr Daily Failure Summary";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 06:00:00";
      Persistent = true;
    };
  };

  # Runtime computation of SHA-256 hashes from monitoring tokens
  # The service reads tokens from sops secrets and writes nginx map files to /run/monitoring-token-hashes
  # Phase 1: elk receives from elk, dino, cogsworth.
  # Phase 2: add wolf/bear/tiger tokens when migrating those hosts.
  systemd.services.monitoring-token-hash-generator = {
    description = "Generate SHA-256 hashes for monitoring bearer tokens";
    wantedBy = [ "multi-user.target" ];
    after = [ "sops-nix.service" ];
    before = [ "nginx.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      mkdir -p /run/monitoring-token-hashes

      elk_hash=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.monitoring_token_elk.path} | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)
      dino_hash=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.monitoring_token_dino.path} | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)
      cogsworth_hash=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.monitoring_token_cogsworth.path} | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)

      cat > /run/monitoring-token-hashes/metrics-map.conf <<EOF
      map \$bearer_token \$valid_metrics_token {
        "$elk_hash" "1";
        "$dino_hash" "1";
        "$cogsworth_hash" "1";
        default "";
      }
      EOF

      cat > /run/monitoring-token-hashes/logs-map.conf <<EOF
      map \$bearer_token \$valid_logs_token {
        "$elk_hash" "1";
        "$dino_hash" "1";
        "$cogsworth_hash" "1";
        default "";
      }
      EOF

      chmod 644 /run/monitoring-token-hashes/*.conf
    '';
  };

  # SOPS secrets
  sops.secrets = {
    apps_ondy_org_route53 = {
      mode = "0400";
    };
    monitoring_token_elk = {
      mode = "0444";
    };
    monitoring_token_dino = {
      mode = "0444";
    };
    monitoring_token_cogsworth = {
      mode = "0444";
    };
    tdarr_api_key = {
      mode = "0440";
      group = "media";
    };
    sonarr_api_key = {
      mode = "0444";
    };
    radarr_api_key = {
      mode = "0444";
    };
    lidarr_api_key = {
      mode = "0444";
    };
    readarr_api_key = {
      mode = "0444";
    };
    prowlarr_api_key = {
      mode = "0444";
    };
    bazarr_api_key = {
      mode = "0444";
    };
    sabnzbd_api_key = {
      mode = "0444";
    };
    jellyfin_api_key = {
      mode = "0444";
    };
  };

  system.stateVersion = "25.11";
}
