{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [ ./hardware-configuration.nix ];

  networking = {
    hostName = "wolf";
    # Required for ZFS - derived from /etc/machine-id
    hostId = "8a3c5d2e";

    # WireGuard tunnel for NFS and monitoring from bear
    wireguard.interfaces.wg0 = {
      ips = [ "10.10.0.1/24" ];
      listenPort = 51820;
      privateKeyFile = config.sops.secrets.wireguard_private_key_wolf.path;
      peers = [
        {
          # bear peer
          publicKey = "br9DBxgicT4P1Heey05srTXJU+9TOuIWH38ZhXmbvRo=";
          allowedIPs = [ "10.10.0.2/32" ];
        }
        {
          # tiger peer
          publicKey = "xv9v5sg/RL4NY+Wq2+LofjtzuUJLarTYH2fkHjCD2gg=";
          allowedIPs = [ "10.10.0.3/32" ];
        }
      ];
    };

    firewall = {
      allowedUDPPorts = [ 51820 ]; # WireGuard
      # Allow NFS, VictoriaMetrics, Loki, and Tdarr on WireGuard interface only
      interfaces.wg0 = {
        allowedTCPPorts = [
          2049 # NFS
          111 # NFS portmapper
          8428 # VictoriaMetrics
          3100 # Loki
          8266 # Tdarr server
        ];
      };
    };
  };

  time.timeZone = "America/New_York";
  i18n = {
    defaultLocale = "en_US.UTF-8";
    extraLocaleSettings = {
      LC_ALL = "en_US.UTF-8";
    };
  };

  # allow building other arch's packages
  boot.binfmt.emulatedSystems = [
    "aarch64-linux"
    "armv7l-linux"
  ];

  # Enable ZFS support
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  boot.zfs.extraPools = [ "storage" ];

  # ZFS memory tuning for 16GB RAM system optimized for media streaming
  boot.kernelParams = [
    "zfs.zfs_arc_max=8589934592" # 8GB max ARC cache
    "zfs.zfs_arc_min=2147483648" # 2GB min ARC cache
    "zfs.zfs_prefetch_disable=0" # Keep prefetch enabled for streaming
    "zfs.zfs_txg_timeout=10" # 10s transaction group timeout for faster writes
  ];

  # Boot loader configuration - GRUB with EFI support
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    devices = [ "nodev" ];
  };
  boot.loader.efi.canTouchEfiVariables = false;

  # Allow svc.deploy to write to website directory
  users.users."svc.deploy".extraGroups = [ "nginx" ];

  # Create media group for shared access to downloads/media
  # Explicitly set GID to ensure consistency across NFS mounts (bear uses same GID)
  users.groups.media = {
    gid = 983;
  };

  # Ensure directories exist with proper permissions
  systemd.tmpfiles.rules = [
    # Website directory - 0775 allows nginx group members (including svc.deploy) to write
    "d /var/www/kyleondy.com 0775 nginx nginx -"
    # Download directories - 0775 allows media group members to read/write
    "d /mnt/storage/downloads 0755 root root -"
    "d /mnt/storage/downloads/complete 0775 root media -"
    "d /mnt/storage/downloads/incomplete 0775 root media -"
    # Media directories - 0775 allows media group members to read/write
    "d /mnt/storage/media 0775 root media -"
    "d /mnt/storage/media/movies 0775 root media -"
    "d /mnt/storage/media/tv 0775 root media -"
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

        # Redirect ondy.org to www.kyleondy.com (requires DNS update to point to wolf)
        "ondy.org" = {
          enable = true;
          provisionCert = true;
          redirectTo = "www.kyleondy.com";
          # route53HostedZoneId not specified - lego will auto-detect the zone
        };

        # Default catch-all server that redirects to www.kyleondy.com
        "_" = {
          enable = true;
          isDefault = true;
          extraDomainNames = [ "www.kyleondy.com" ];
        };
      };
    };

    harmonia = {
      enable = true;
      domainName = "nix-cache.apps.ondy.org";
      provisionCert = true;
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

      # Bearer token authentication - hashes computed at runtime from sops secrets
      # The systemd service monitoring-token-hash-generator generates nginx map files
      # at /run/monitoring-token-hashes/*.conf which are included by nginx at runtime
      # No tokenHashes needed here - nginx includes the maps directly

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
          "eno3"
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

      # Local monitoring agents (wolf monitors itself)
      nodeExporter = {
        enable = true;
      };

      nginxExporter = {
        enable = true;
      };

      nginxlogExporter = {
        enable = true;
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
                  host = "wolf";
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
                  host = "wolf";
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
                  host = "wolf";
                };
              }
            ];
          }
          # Exportarr metrics for *arr services
          {
            job_name = "exportarr-sonarr";
            static_configs = [
              {
                targets = [ "127.0.0.1:9707" ];
                labels = {
                  host = "wolf";
                  service = "sonarr";
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
                  host = "wolf";
                  service = "radarr";
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
                  host = "wolf";
                  service = "lidarr";
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
                  host = "wolf";
                  service = "readarr";
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
                  host = "wolf";
                  service = "prowlarr";
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
                  host = "wolf";
                  service = "bazarr";
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
                  host = "wolf";
                  service = "sabnzbd";
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
          host = "wolf";
        };
      };
    };

    prowlarr = {
      enable = true;
      group = "media";
      domainName = "prowlarr.apps.ondy.org";
      provisionCert = true;
    };

    sabnzbd = {
      enable = true;
      group = "media";
      domainName = "sabnzbd.apps.ondy.org";
      provisionCert = true;
    };

    bazarr = {
      enable = true;
      group = "media";
      domainName = "bazarr.apps.ondy.org";
      provisionCert = true;
    };

    lidarr = {
      enable = true;
      group = "media";
      domainName = "lidarr.apps.ondy.org";
      provisionCert = true;
    };

    radarr = {
      enable = true;
      group = "media";
      domainName = "radarr.apps.ondy.org";
      provisionCert = true;
    };

    readarr = {
      enable = true;
      group = "media";
      domainName = "readarr.apps.ondy.org";
      provisionCert = true;
    };

    sonarr = {
      enable = true;
      group = "media";
      domainName = "sonarr.apps.ondy.org";
      provisionCert = true;
    };

    jellyfin = {
      enable = false;
      group = "media";
      domainName = "jellyfin.apps.ondy.org";
      provisionCert = true;
      transcodeCleanupInterval = "36 hours";
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
  };

  # NFS server - export media to bear and tiger over WireGuard
  services.nfs.server = {
    enable = true;
    exports = ''
      /mnt/storage/media 10.10.0.2(rw,sync,no_subtree_check,no_root_squash) 10.10.0.3(rw,sync,no_subtree_check,no_root_squash)
    '';
  };

  # SOPS secrets for monitoring and WireGuard
  sops.secrets = {
    monitoring_token_tiger = {
      # Used by sops template for runtime hash computation and nginx auth
      mode = "0444";
    };
    monitoring_token_dino = {
      # Used by sops template for runtime hash computation and nginx auth
      mode = "0444";
    };
    monitoring_token_wolf = {
      # Used by sops template for runtime hash computation and nginx auth
      mode = "0444";
    };
    monitoring_token_bear = {
      # Used by sops template for runtime hash computation and nginx auth
      mode = "0444";
    };
    monitoring_token_cogsworth = {
      # Used by sops template for runtime hash computation and nginx auth
      mode = "0444";
    };
    wireguard_private_key_wolf = {
      mode = "0400";
    };
    tdarr_api_key = {
      mode = "0400";
    };

    # Exportarr API keys for *arr services
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
  };

  # Runtime computation of SHA-256 hashes from monitoring tokens
  # Hash computation is now handled by a systemd service that runs at boot
  # The service reads tokens from sops secrets and writes nginx map files to /run/monitoring-token-hashes
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
      # Ensure runtime directory exists
      mkdir -p /run/monitoring-token-hashes

      # Read tokens from sops secrets and compute SHA-256 hashes
      tiger_hash=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.monitoring_token_tiger.path} | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)
      dino_hash=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.monitoring_token_dino.path} | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)
      wolf_hash=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.monitoring_token_wolf.path} | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)
      bear_hash=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.monitoring_token_bear.path} | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)
      cogsworth_hash=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.monitoring_token_cogsworth.path} | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)

      # Write metrics token map for nginx (VictoriaMetrics ingestion)
      cat > /run/monitoring-token-hashes/metrics-map.conf <<EOF
      # Validate token hash for VictoriaMetrics ingestion
      # Clients must send SHA-256 hash of their token as the bearer token
      map \$bearer_token \$valid_metrics_token {
        "$tiger_hash" "1";
        "$dino_hash" "1";
        "$wolf_hash" "1";
        "$bear_hash" "1";
        "$cogsworth_hash" "1";
        default "";
      }
      EOF

      # Write logs token map for nginx (Loki ingestion)
      cat > /run/monitoring-token-hashes/logs-map.conf <<EOF
      # Validate token hash for Loki ingestion
      # Clients must send SHA-256 hash of their token as the bearer token
      map \$bearer_token \$valid_logs_token {
        "$tiger_hash" "1";
        "$dino_hash" "1";
        "$wolf_hash" "1";
        "$bear_hash" "1";
        "$cogsworth_hash" "1";
        default "";
      }
      EOF

      # Set permissions so nginx can read them
      chmod 644 /run/monitoring-token-hashes/*.conf
    '';
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.05";
}
