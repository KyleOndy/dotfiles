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
      allowedTCPPorts = [
        80
        443
      ];
      allowedUDPPorts = [
        # 51821 # WireGuard (home tunnel) - disabled with ytdl-sub
      ];
    };

    # WireGuard tunnel to home for residential IP routing (YouTube downloads)
    # Disabled along with ytdl-sub - re-enable when resuming YouTube downloads
    # wireguard.interfaces.wg-home = {
    #   ips = [ "192.168.5.3/32" ];
    #   listenPort = 51821;
    #   privateKeyFile = config.sops.secrets.unifi_wireguard_private_elk.path;
    #   table = "100"; # Routes go into table 100, not the main table
    #
    #   postSetup = ''
    #     ${pkgs.iproute2}/bin/ip rule add from 192.168.5.3 table 100 priority 100
    #   '';
    #
    #   postShutdown = ''
    #     ${pkgs.iproute2}/bin/ip rule del from 192.168.5.3 table 100 priority 100 || true
    #   '';
    #
    #   peers = [
    #     {
    #       publicKey = "r4+6mEOGrmldIt+aSAYGzEDLMppbugpkyq2oBfxDo1M=";
    #       endpoint = "home.1ella.com:51820";
    #       allowedIPs = [ "0.0.0.0/0" ];
    #       persistentKeepalive = 25;
    #       dynamicEndpointRefreshSeconds = 300;
    #     }
    #   ];
    # };
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
  users.users."svc.deploy".extraGroups = [ "caddy" ];

  # Create media group for shared access to downloads/media
  users.groups.media = {
    gid = 983;
  };

  # Jellyfin user permissions for media access and hardware transcoding
  users.users.kyle.extraGroups = [ "media" ];
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
    (writeShellScriptBin "alert-silence" ''
      export PATH="/run/wrappers/bin:${
        lib.makeBinPath [
          coreutils
          curl
          jq
        ]
      }"
      ${builtins.readFile ./scripts/alert-silence.sh}
    '')
  ];

  # Ensure directories exist with proper permissions
  systemd.tmpfiles.rules = [
    # Website directory - svc.deploy owns so it can set timestamps via rsync; caddy group for serving
    "d /var/www/kyleondy.com 0775 svc.deploy caddy -"
    # Download directories - 0775 allows media group members to read/write
    "d /mnt/storage/downloads 0755 root root -"
    "d /mnt/storage/downloads/complete 0775 root media -"
    # SABnzbd incomplete dir on NVMe for faster par2/unpack I/O
    "d /var/lib/sabnzbd/incomplete 0775 sabnzbd media -"
    # Download category directories (match SABnzbd categories)
    "d /mnt/storage/downloads/complete/movies 0775 root media -"
    "d /mnt/storage/downloads/complete/tv 0775 root media -"
    "d /mnt/storage/downloads/complete/music 0775 root media -"
    "d /mnt/storage/downloads/complete/books 0775 root media -"
    # Media directories - setgid so new files inherit media group
    "d /mnt/storage/media 2775 root media -"
    "d /mnt/storage/media/movies 2775 root media -"
    "d /mnt/storage/media/tv 2775 root media -"
    "d /mnt/storage/media/music 2775 root media -"
    "d /mnt/storage/media/books 2775 root media -"
    "d /mnt/storage/media/tmp 2775 root media -"
    "d /mnt/storage/media/yt 2775 root media -"
  ];

  systemFoundry = {
    # Enable Docker for OCI containers
    docker.enable = true;

    caddyReverseProxy = {
      enable = true;
      acme = {
        email = "kyle@ondy.org";
        credentialsSecret = "apps_ondy_org_route53";
      };
      infraDomain = "elk.infra.ondy.org";

      sites = {
        # Main website (individual cert, kyleondy.com zone)
        "www.kyleondy.com" = {
          enable = true;
          staticRoot = "/var/www/kyleondy.com";
        };

        # Redirect apex domain to www
        "kyleondy.com" = {
          enable = true;
          redirectTo = "www.kyleondy.com";
        };

        # Redirect ondy.org to www.kyleondy.com
        "ondy.org" = {
          enable = true;
          redirectTo = "www.kyleondy.com";
        };

        # Default catch-all that redirects to www.kyleondy.com
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
      domain = "elk.infra.ondy.org";
      monitoringBasicAuth = config.sops.secrets.monitoring_basicauth.path;

      # Retention configuration
      retention = {
        metrics = 400; # days
        logs = 400; # days
      };

      # Server-side components (central monitoring server)
      victoriametrics = {
        enable = true;
        # domain defaults to metrics.elk.infra.ondy.org (covered by wildcard cert)
      };

      loki = {
        enable = true;
        # domain defaults to loki.elk.infra.ondy.org (covered by wildcard cert)
        instanceInterfaceNames = [
          "enp5s0"
          "lo"
        ];
      };

      grafana = {
        enable = true;
        # domain defaults to grafana.elk.infra.ondy.org (covered by wildcard cert)
      };

      alertmanager = {
        enable = true;
      };

      vmalert = {
        enable = true;
        # domain defaults to vmalert.elk.infra.ondy.org (covered by wildcard cert)
      };

      # Local monitoring agents (elk monitors itself)
      nodeExporter = {
        enable = true;
      };

      # nginx exporters disabled — elk uses Caddy (metrics at localhost:2019/metrics)
      nginxExporter = {
        enable = false;
      };

      nginxlogExporter = {
        enable = false;
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
          enable = true;
          apiKeyFile = config.sops.secrets.sonarr_api_key.path;
        };

        radarr = {
          enable = true;
          apiKeyFile = config.sops.secrets.radarr_api_key.path;
        };

        lidarr = {
          enable = true;
          apiKeyFile = config.sops.secrets.lidarr_api_key.path;
          enableAdditionalMetrics = false;
        };

        readarr = {
          enable = true;
          apiKeyFile = config.sops.secrets.readarr_api_key.path;
        };

        prowlarr = {
          enable = true;
          apiKeyFile = config.sops.secrets.prowlarr_api_key.path;
        };

        bazarr = {
          enable = true;
          apiKeyFile = config.sops.secrets.bazarr_api_key.path;
        };

        sabnzbd = {
          enable = true;
          apiKeyFile = config.sops.secrets.sabnzbd_api_key.path;
        };
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
            job_name = "caddy";
            static_configs = [
              {
                targets = [ "127.0.0.1:2019" ];
                labels = {
                  host = "elk";
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
          {
            job_name = "exportarr-sonarr";
            static_configs = [
              {
                targets = [ "127.0.0.1:9707" ];
                labels = {
                  host = "elk";
                };
              }
            ];
          }
          {
            job_name = "exportarr-radarr";
            static_configs = [
              {
                targets = [ "127.0.0.1:9708" ];
                labels = {
                  host = "elk";
                };
              }
            ];
          }
          {
            job_name = "exportarr-lidarr";
            scrape_interval = "60s";
            scrape_timeout = "30s";
            static_configs = [
              {
                targets = [ "127.0.0.1:9709" ];
                labels = {
                  host = "elk";
                };
              }
            ];
          }
          {
            job_name = "exportarr-readarr";
            static_configs = [
              {
                targets = [ "127.0.0.1:9710" ];
                labels = {
                  host = "elk";
                };
              }
            ];
          }
          {
            job_name = "exportarr-prowlarr";
            static_configs = [
              {
                targets = [ "127.0.0.1:9711" ];
                labels = {
                  host = "elk";
                };
              }
            ];
          }
          {
            job_name = "exportarr-bazarr";
            static_configs = [
              {
                targets = [ "127.0.0.1:9712" ];
                labels = {
                  host = "elk";
                };
              }
            ];
          }
          {
            job_name = "exportarr-sabnzbd";
            static_configs = [
              {
                targets = [ "127.0.0.1:9713" ];
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
      enable = true;
      group = "media";
      domainName = "prowlarr.elk.infra.ondy.org";
      provisionCert = true;
    };

    sabnzbd = {
      enable = true;
      group = "media";
      domainName = "sabnzbd.elk.infra.ondy.org";
      provisionCert = true;
    };

    bazarr = {
      enable = true;
      group = "media";
      domainName = "bazarr.elk.infra.ondy.org";
      provisionCert = true;
    };

    lidarr = {
      enable = true;
      group = "media";
      domainName = "lidarr.elk.infra.ondy.org";
      provisionCert = true;
    };

    navidrome = {
      enable = true;
      domainName = "navidrome.elk.infra.ondy.org";
      provisionCert = true;
    };

    radarr = {
      enable = true;
      group = "media";
      domainName = "radarr.elk.infra.ondy.org";
      provisionCert = true;
    };

    readarr = {
      enable = true;
      group = "media";
      domainName = "readarr.elk.infra.ondy.org";
      provisionCert = true;
    };

    sonarr = {
      enable = true;
      group = "media";
      domainName = "sonarr.elk.infra.ondy.org";
      provisionCert = true;
    };

    # Jellyfin media server with QuickSync transcoding (local media at /mnt/storage/media)
    jellyfin = {
      enable = true;
      group = "media";
      domainName = "jellyfin.elk.infra.ondy.org";
      # provisionCert not needed — covered by *.elk.infra.ondy.org wildcard cert
      transcodeCleanupInterval = "36 hours";
      debugAuthLogging = true;
      transcodeDebugLogging = true;
      installPlaybackReportingPlugin = true;
      backup = {
        enable = true;
        apiKeyFile = config.sops.secrets.jellyfin_api_key.path;
      };
    };

    jellyseerr = {
      enable = true;
      domainName = "jellyseerr.elk.infra.ondy.org";
      # provisionCert not needed — covered by *.elk.infra.ondy.org wildcard cert
    };

    harmonia = {
      enable = true;
      domainName = "cache.apps.ondy.org";
      provisionCert = true;
      signKeyPath = config.sops.secrets.harmonia_secret.path;
    };

  };

  # Public domain aliases for DNS cutover (*.apps.ondy.org -> elk)
  # Each gets its own vhost + individual cert via Route53 DNS-01.
  systemFoundry.caddyReverseProxy.sites = {
    "sonarr.elk.infra.ondy.org".publicAliases = [ "sonarr.apps.ondy.org" ];
    "radarr.elk.infra.ondy.org".publicAliases = [ "radarr.apps.ondy.org" ];
    "lidarr.elk.infra.ondy.org".publicAliases = [ "lidarr.apps.ondy.org" ];
    "navidrome.elk.infra.ondy.org".publicAliases = [ "navidrome.apps.ondy.org" ];
    "readarr.elk.infra.ondy.org".publicAliases = [ "readarr.apps.ondy.org" ];
    "prowlarr.elk.infra.ondy.org".publicAliases = [ "prowlarr.apps.ondy.org" ];
    "sabnzbd.elk.infra.ondy.org".publicAliases = [ "sabnzbd.apps.ondy.org" ];
    "bazarr.elk.infra.ondy.org".publicAliases = [ "bazarr.apps.ondy.org" ];
    "jellyfin.elk.infra.ondy.org".publicAliases = [ "jellyfin.apps.ondy.org" ];
    "jellyseerr.elk.infra.ondy.org".publicAliases = [ "jellyseerr.apps.ondy.org" ];
    "grafana.elk.infra.ondy.org".publicAliases = [ "grafana.apps.ondy.org" ];
    "loki.elk.infra.ondy.org".publicAliases = [ "loki.apps.ondy.org" ];
    "metrics.elk.infra.ondy.org".publicAliases = [ "metrics.apps.ondy.org" ];
    "vmalert.elk.infra.ondy.org".publicAliases = [ "vmalert.apps.ondy.org" ];
  };

  # Subtitle extractor - scans media library hourly for missing subtitle sidecars
  systemFoundry.subtitleExtractor = {
    enable = false;
    mediaPath = "/mnt/storage/media";
    schedule = "hourly";
    user = "root";
    group = "root";
  };

  # Media normalizer - transcodes EAC3→AAC and strips PGS/DVD bitmap subtitles
  systemFoundry.mediaNormalizer = {
    enable = true;
    mediaPath = "/mnt/storage/media";
    tempPath = "/mnt/storage/media/tmp";
    sourceCodecs = [ "eac3" ];
    removeSubtitleCodecs = [
      "hdmv_pgs_subtitle"
      "dvd_subtitle"
    ];
  };

  # Whisper subtitle generation - generates .en.whisper.srt via whisper-cpp CPU
  systemFoundry.whisperSubtitles = {
    enable = true;
    model = "medium";
    threads = 8;
  };

  # YouTube downloader - downloads videos from subscribed channels via ytdl-sub
  systemFoundry.ytdlSub = {
    enable = false; # Disabled - YouTube throttling. Re-enable once resolved.
    media_dir = "/mnt/storage/media/yt";
    temp_dir = "/mnt/storage/downloads/youtube-temp";
    source_address = "192.168.5.3"; # Route downloads through WireGuard home tunnel
    wireguard_service = "wireguard-wg-home.service";

    tiers = {
      # Frequent posters: checked daily, limited to 10 videos to reduce request volume
      daily = {
        schedule = "*-*-* 03:00:00";
        max_videos = 10;
      };
      # Everything else: checked weekly, higher video limit for catch-up
      weekly = {
        schedule = "Mon *-*-* 03:00:00";
        max_videos = 20;
      };
    };

    channels = {
      Cycling = [
        "@BeauMiles"
        "@BermPeakExpress"
        "@bike2reality814"
        "@BIKEPACKINGcom"
        "@BikePak"
        "@chadweberg1" # Chad Weberg
        "@ChumbaUSABikes"
        "@Cycling366"
        {
          name = "@Danny_MacAskill";
          tier = "daily";
        }
        {
          name = "@DirtyTeethMTB";
          tier = "daily";
        }
        "@duzer"
        "@DylanJohnsonCycling"
        "@EFProCycling"
        {
          name = "@FarBeyond-EFPC";
          tier = "daily";
        }
        {
          name = "@FullBeansCyclingCompany";
          tier = "daily";
        }
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
        {
          name = "@lesperitdelbikepacking";
          tier = "daily";
        }
        "@MediocreAmateur"
        "@MickTurnbullFilms"
        "@msoleilblais74"
        "@omniumcargo"
        "@panoramacycles"
        "@PatrickMcGrady1"
        "@PaulComponentEngineering"
        "@pnwbikepacking"
        {
          name = "@raphafilms";
          tier = "daily";
        }
        "@RideProductionsNZ"
        "@RousLigon"
        "@SethsBikeHacks"
        "@sofianeshl"
        "@sportscientist" # Stephen Seiler
        "@stephanwieser"
        {
          name = "@TailfinCycling";
          tier = "daily";
        }
        "@TENTISTHENEWRENT"
        {
          name = "@the_dirtbags";
          tier = "daily";
        }
        "@themountainraces"
        {
          name = "@TheVCAdventures";
          tier = "daily";
        } # The Vegan Cyclist
        "@tristanbogaard"
        "@tristantakevideo"
        "@TurnCycling"
        "@ValleyPreferredCyclingCenter"
        "@wattwagon"
        "@wheelstowaves"
        {
          name = "@worstretirementever";
          tier = "daily";
        } # Phil Gaimon
      ];
      Science = [
        "@AlphaPhoenixChannel"
        "@BetaPhoenixChannel"
        "@miniminuteman773"
      ];
      Maker = [
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
      ];
      Entertainment = [
        "@2MuchColinFurze"
        "@Ben_Brainard"
        "@CaptainDisillusion"
        {
          name = "@CharlieBerens";
          tier = "daily";
        }
        "@colinfurze"
        "@DudeDad"
        {
          name = "@Gossip.Goblin";
          tier = "daily";
        }
        "@GxAce"
        "@kaptainkristian"
        "@kurzgesagt"
        "@PracticalEngineeringChannel"
        "@RudyAyoub"
        "@SampsonBoatCo"
        {
          name = "@theslappablejerk";
          shorts = false;
        }
        "@treykennedy"
        "@whistlindiesel"
      ];
      Tech = [
        "@AdamJames-tv"
        "@KRAZAM"
        "@programmersarealsohuman5909" # Kai Lentit
      ];
      Outdoor = [
        "@bronandjacob"
        {
          name = "@ChrisburkardStudio";
          tier = "daily";
        }
        {
          name = "@courtneyevewhite";
          tier = "daily";
        }
        "@RabEquipment"
        "@theaudaciousreport"
      ];
    };
  };

  # Jellyfin prune - deletes watched YouTube videos from disk after 2 days
  # Jellyfin and media are both local on elk — no path translation needed.
  systemd.services.jellyfin-prune = {
    enable = false; # Disabled along with ytdl-sub
    startAt = "*-*-* 06:00:00"; # 6am
    path = with pkgs; [
      bashInteractive
      curl
      fd
      jq
    ];
    environment = {
      TOKEN_FILE = config.sops.secrets.jellyfin_api_key.path;
      DATA_DIR = config.systemFoundry.ytdlSub.data_dir;
      MEDIA_DIR = config.systemFoundry.ytdlSub.media_dir;
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
          'http://127.0.0.1:8096/Items?userId=04156d27514048bdbe6fc0adb8c28499&recursive=true&parentId=e59b37148e0ff06f0d35b0c3c714e75c&fields=Path&enableUserData=true&enableTotalRecordCount=false&enableImages=false' \
          -H 'accept: application/json' \
          -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | jq -r '.Items[] | select(.UserData.PlayCount >= 1) | .Path'
      }

      update_lib() {
        curl -Ss -X 'POST' \
          'http://127.0.0.1:8096/ScheduledTasks/Running/7738148ffcd07979c7ceb148e06b3aed' \
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
            base="''${vid%.*}"
            rm -vf "''${base}.nfo"
            rm -vf "''${base}.info.json"
            rm -vf "''${base}-thumb.jpg"
          else
            echo "Can not find $vid"
          fi
        done

        fd --type=directory --type=empty . "$MEDIA_DIR" -X rmdir -v
        echo "Updating library"
        update_lib
      }

      main
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
        "\(.index)|\(.tags.language // "" | if . == "" then "und" else . end)|\(.tags.title // "")"
      ')

      if [[ -z "$TEXT_SUBS" ]]; then
        echo "No text-based subtitles found in $FILE_PATH"
        exit 0
      fi

      declare -A LANG_COUNTS

      while IFS='|' read -r STREAM_IDX LANG TITLE; do
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

        [[ -z "$LANG" ]] && LANG="und"

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

        if ${pkgs.ffmpeg-headless}/bin/ffmpeg -nostdin -v error -i "$FILE_PATH" \
            -map "0:$STREAM_IDX" -c:s srt "$OUTPUT_FILE" 2>/dev/null; then
          if [[ ! -s "$OUTPUT_FILE" ]]; then
            rm -f "$OUTPUT_FILE"
            echo "Removed empty sidecar: $OUTPUT_FILE" >&2
          else
            echo "Extracted: $OUTPUT_FILE (stream $STREAM_IDX: $LANG''${TITLE:+ - $TITLE})"
          fi
        else
          rm -f "$OUTPUT_FILE"
          echo "Failed to extract stream $STREAM_IDX from $FILE_PATH" >&2
        fi
      done <<< "$TEXT_SUBS"
    '';
  };

  # SOPS secrets
  sops.secrets = {
    # Route53 credentials for Caddy ACME DNS-01 challenge (read by systemd as root)
    apps_ondy_org_route53 = {
      mode = "0400";
    };
    # Basic auth credentials for monitoring write endpoints (read by Caddy process)
    # Format: "username $2a$..." (bcrypt hash), one entry per line
    monitoring_basicauth = {
      mode = "0440";
      group = "caddy";
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
    harmonia_secret = {
      owner = "harmonia";
      mode = "0400";
    };
    # unifi_wireguard_private_elk = { # Disabled with wg-home tunnel
    #   mode = "0400";
    # };
  };

  system.stateVersion = "25.11";
}
