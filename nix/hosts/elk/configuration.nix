{
  config,
  pkgs,
  lib,
  ...
}:
let
  wolfNfs = {
    src = "10.10.0.1:/mnt/storage/media";
    mountPoint = "/mnt/wolf-media";
    opts = "nfsvers=4.2,soft,timeo=30,retrans=2,noatime,acregmin=60,acregmax=600,acdirmin=60,acdirmax=600,ro";
  };
in
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
      allowedUDPPorts = [ 51820 ]; # WireGuard
    };

    wireguard.interfaces.wg0 = {
      ips = [ "10.10.0.4/24" ];
      listenPort = 51820;
      privateKeyFile = config.sops.secrets.wireguard_private_key_elk.path;
      peers = [
        {
          # wolf peer
          publicKey = "S7jDjWEY/0RrPsIshmRU1rgr4gC+eL4POf0OlujofW8=";
          endpoint = "51.79.99.201:51820";
          allowedIPs = [ "10.10.0.1/32" ];
          persistentKeepalive = 25;
        }
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

  boot.supportedFilesystems = [ "nfs" ];

  # TCP buffer tuning for NFS over WireGuard
  boot.kernel.sysctl = {
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.ipv4.tcp_rmem" = "4096 1048576 16777216";
    "net.ipv4.tcp_wmem" = "4096 1048576 16777216";
  };

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
    (writeShellScriptBin "media-migration-status" ''
      export PATH="${
        lib.makeBinPath [
          coreutils
          findutils
          gnugrep
          gnused
          util-linux
        ]
      }"
      ${builtins.readFile ./scripts/media-migration-status.sh}
    '')
    (writeShellScriptBin "media-migration-sync" ''
      export PATH="${
        lib.makeBinPath [
          coreutils
          findutils
          rsync
          util-linux
        ]
      }"
      ${builtins.readFile ./scripts/media-migration-sync.sh}
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
    # Local media backing directories (upper layer for overlayfs)
    # setgid (2775) so subdirs created by rsync inherit the media group
    "d /mnt/storage/media-local 2775 root media -"
    "d /mnt/storage/media-local/movies 2775 root media -"
    "d /mnt/storage/media-local/tv 2775 root media -"
    "d /mnt/storage/media-local/music 2775 root media -"
    "d /mnt/storage/media-local/books 2775 root media -"
    "d /mnt/storage/media-local/tmp 2775 root media -"
    "d /mnt/storage/media-local/yt 2775 root media -"
    # Overlay mount point and support directories
    "d /mnt/storage/media 0775 root media -"
    "d /mnt/wolf-media 0755 root root -"
    "d /mnt/storage/media-overlay-work 0775 root media -"
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

  };

  # Infra domain aliases — test services at {service}.elk.infra.ondy.org before swinging public DNS
  services.nginx.virtualHosts = {
    "jellyfin.apps.ondy.org".serverAliases = [ "jellyfin.elk.infra.ondy.org" ];
    "jellyseerr.apps.ondy.org".serverAliases = [ "jellyseerr.elk.infra.ondy.org" ];
    "grafana.apps.ondy.org".serverAliases = [ "grafana.elk.infra.ondy.org" ];
    "metrics.apps.ondy.org".serverAliases = [ "metrics.elk.infra.ondy.org" ];
    "loki.apps.ondy.org".serverAliases = [ "loki.elk.infra.ondy.org" ];
    "vmalert.apps.ondy.org".serverAliases = [ "vmalert.elk.infra.ondy.org" ];
  };

  security.acme.certs = {
    "jellyfin.apps.ondy.org".extraDomainNames = [ "jellyfin.elk.infra.ondy.org" ];
    "jellyseerr.apps.ondy.org".extraDomainNames = [ "jellyseerr.elk.infra.ondy.org" ];
    "grafana.apps.ondy.org".extraDomainNames = [ "grafana.elk.infra.ondy.org" ];
    "metrics.apps.ondy.org".extraDomainNames = [ "metrics.elk.infra.ondy.org" ];
    "loki.apps.ondy.org".extraDomainNames = [ "loki.elk.infra.ondy.org" ];
    "vmalert.apps.ondy.org".extraDomainNames = [ "vmalert.elk.infra.ondy.org" ];
  };

  # Subtitle extractor - scans media library hourly for missing subtitle sidecars
  systemFoundry.subtitleExtractor = {
    enable = true;
    mediaPath = "/mnt/storage/media";
    schedule = "hourly";
    user = "root";
    group = "root";
  };

  # YouTube downloader - downloads videos from subscribed channels via ytdl-sub
  systemFoundry.ytdlSub = {
    enable = true;
    media_dir = "/mnt/storage/media/yt";
    temp_dir = "/mnt/storage/downloads/youtube-temp";

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
        "@ChrisburkardStudio"
        "@courtneyevewhite"
        "@RabEquipment"
        "@theaudaciousreport"
      ];
    };
  };

  # Mount media overlay (wolf NFS lower + elk local upper) with graceful fallback
  systemd.services.media-mount-setup = {
    description = "Mount media overlay (wolf NFS + elk local) or fallback to local-only";
    after = [
      "wireguard-wg0.service"
      "network-online.target"
      "local-fs.target"
    ];
    wants = [
      "wireguard-wg0.service"
      "network-online.target"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [
      util-linux
      coreutils
      nfs-utils
    ];
    script = ''
      set -euo pipefail

      if mountpoint -q /mnt/storage/media; then
        echo "/mnt/storage/media already mounted"
        exit 0
      fi

      # Try direct NFS mount (avoids systemd unit entering failed state on timeout)
      if mount -t nfs -o ${wolfNfs.opts} ${wolfNfs.src} ${wolfNfs.mountPoint} 2>/dev/null \
        && mountpoint -q ${wolfNfs.mountPoint}; then
        echo "NFS available, mounting overlay"
        mount -t overlay overlay \
          -o lowerdir=${wolfNfs.mountPoint},upperdir=/mnt/storage/media-local,workdir=/mnt/storage/media-overlay-work \
          /mnt/storage/media
        echo "Overlay active: elk-local + wolf-NFS"
      else
        echo "Wolf unavailable, bind-mounting local media only"
        mount --bind /mnt/storage/media-local /mnt/storage/media
        echo "Local-only mode active"
      fi
    '';
  };

  # Upgrade local-only bind-mount to overlay when wolf comes online
  systemd.services.media-mount-upgrade = {
    description = "Upgrade local-only media mount to overlay if wolf becomes available";
    serviceConfig.Type = "oneshot";
    path = with pkgs; [
      util-linux
      coreutils
      nfs-utils
    ];
    script = ''
      set -euo pipefail
      MOUNT_TYPE=$(findmnt -n -o FSTYPE /mnt/storage/media 2>/dev/null || echo "none")
      if [ "$MOUNT_TYPE" = "overlay" ]; then
        exit 0  # already overlay
      fi

      if ! mountpoint -q ${wolfNfs.mountPoint}; then
        mount -t nfs -o ${wolfNfs.opts} ${wolfNfs.src} ${wolfNfs.mountPoint} 2>/dev/null || true
      fi

      if mountpoint -q ${wolfNfs.mountPoint}; then
        echo "Wolf available, upgrading to overlay"
        umount /mnt/storage/media
        mount -t overlay overlay \
          -o lowerdir=${wolfNfs.mountPoint},upperdir=/mnt/storage/media-local,workdir=/mnt/storage/media-overlay-work \
          /mnt/storage/media
        echo "Upgraded to overlay mode"
      fi
    '';
  };

  systemd.timers.media-mount-upgrade = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "10min";
    };
  };

  # Jellyfin must wait for media to be mounted
  systemd.services.jellyfin = {
    after = [ "media-mount-setup.service" ];
    requires = [ "media-mount-setup.service" ];
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
      DATA_DIR = config.systemFoundry.ytdlSub.data_dir;
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

        if ${pkgs.ffmpeg-headless}/bin/ffmpeg -v error -i "$FILE_PATH" \
            -map "0:$STREAM_IDX" -c:s srt "$OUTPUT_FILE" 2>/dev/null; then
          echo "Extracted: $OUTPUT_FILE (stream $STREAM_IDX: $LANG''${TITLE:+ - $TITLE})"
        else
          echo "Failed to extract stream $STREAM_IDX from $FILE_PATH" >&2
        fi
      done <<< "$TEXT_SUBS"
    '';
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
    wireguard_private_key_elk = {
      mode = "0400";
    };
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
