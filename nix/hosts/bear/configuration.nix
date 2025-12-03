{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [ ./hardware-configuration.nix ];

  networking = {
    hostName = "bear";
    # Required for mdadm - derived from /etc/machine-id
    hostId = "b3a8f1c4"; # Will be regenerated on first boot

    # WireGuard tunnel to wolf for NFS and monitoring
    wireguard.interfaces.wg0 = {
      ips = [ "10.10.0.2/24" ];
      listenPort = 51820;
      privateKeyFile = config.sops.secrets.wireguard_private_key_bear.path;
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

    firewall.allowedUDPPorts = [ 51820 ];
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

  # NFS mount for media over WireGuard from wolf
  fileSystems."/mnt/media" = {
    device = "10.10.0.1:/mnt/storage/media";
    fsType = "nfs";
    options = [
      "nfsvers=4.2"
      "soft"
      "timeo=30"
      "retrans=2"
      "_netdev" # Mount after network is up
    ];
  };

  # Intel QuickSync hardware transcoding support
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      vpl-gpu-rt # Intel oneVPL GPU runtime
      intel-media-driver # VA-API driver (iHD)
      libvdpau-va-gl # VDPAU compatibility
      intel-compute-runtime # OpenCL for tonemapping and subtitle burn-in
      ocl-icd # OpenCL ICD loader
    ];
  };

  # Expose OpenCL ICD file for Jellyfin HDR tonemapping
  environment.etc."OpenCL/vendors/intel-neo.icd".source =
    "${pkgs.intel-compute-runtime}/etc/OpenCL/vendors/intel-neo.icd";

  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "iHD";
  };

  # System packages
  environment.systemPackages = with pkgs; [
    intel-gpu-tools # intel_gpu_top for monitoring GPU usage
  ];

  # Create media group for shared access to media files
  # GID must match wolf's media group (983) for NFS access
  users.groups.media = {
    gid = 983;
  };

  # Jellyfin user permissions for media access and hardware transcoding
  users.users.jellyfin.extraGroups = [
    "media"
    "render" # Intel QuickSync GPU access
    "video" # Intel QuickSync GPU access
  ];
  systemd.services.jellyfin.serviceConfig = {
    SupplementaryGroups = [
      "media"
      "render"
      "video"
    ];
  };

  systemFoundry = {
    # Enable Docker for OCI containers
    docker.enable = true;

    nginxReverseProxy = {
      acme = {
        email = "kyle@ondy.org";
        dnsProvider = "route53";
        credentialsSecret = "apps_ondy_org_route53";
      };
    };

    # Jellyfin media server with QuickSync transcoding
    jellyfin = {
      enable = true;
      group = "media";
      domainName = "jellyfin.apps.ondy.org";
      provisionCert = true;
      transcodeCleanupInterval = "36 hours";
    };

    # Tdarr node for hardware transcoding with Intel QuickSync
    tdarr.node = {
      enable = true;
      serverUrl = "http://10.10.0.1:8266";
      mediaPath = "/mnt/media";
      nodeName = "bear";
      gpuWorkers = 1;
      cpuWorkers = 2;
      enableGpu = true;
      pathTranslators = [
        {
          from = "/mnt/storage/media";
          to = "/mnt/media";
        }
      ];
      apiKeyFile = config.sops.secrets.tdarr_api_key.path;
    };

    # Monitoring agents - send metrics/logs to wolf over WireGuard
    monitoringStack = {
      enable = true;

      # Local monitoring agents
      nodeExporter = {
        enable = true;
      };

      nginxExporter = {
        enable = true;
      };

      nginxlogExporter = {
        enable = true;
      };

      vmagent = {
        enable = true;
        # Send metrics to wolf VictoriaMetrics over internet with bearer token auth
        remoteWriteUrl = "https://metrics.apps.ondy.org/api/v1/write";
        bearerTokenFile = config.sops.secrets.monitoring_token_bear.path;
        scrapeConfigs = [
          {
            job_name = "node";
            static_configs = [
              {
                targets = [ "127.0.0.1:9100" ];
                labels = {
                  host = "bear";
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
                  host = "bear";
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
                  host = "bear";
                };
              }
            ];
          }
        ];
      };

      promtail = {
        enable = true;
        # Send logs to wolf Loki over internet with bearer token auth
        lokiUrl = "https://loki.apps.ondy.org/loki/api/v1/push";
        bearerTokenFile = config.sops.secrets.monitoring_token_bear.path;
        extraLabels = {
          host = "bear";
        };
      };
    };
  };

  # SOPS secrets
  sops.secrets = {
    wireguard_private_key_bear = {
      mode = "0400";
    };
    apps_ondy_org_route53 = {
      mode = "0400";
    };
    tdarr_api_key = {
      mode = "0400";
    };
    monitoring_token_bear = {
      # vmagent/promtail services run as DynamicUser, which means they can't be
      # assigned file ownership directly. Using mode 0444 allows the services to
      # read it. This is acceptable since the token is only used for authentication
      # to our own VictoriaMetrics/Loki instances, not external services.
      mode = "0444";
    };
  };

  system.stateVersion = "24.05";
}
