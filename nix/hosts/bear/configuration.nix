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
  boot.supportedFilesystems = [ "nfs" ];

  # mdadm configuration for software RAID
  # Use PROGRAM to log events to journald (picked up by promtail)
  environment.etc."mdadm-alert.sh" = {
    mode = "0755";
    text = ''
      #!${pkgs.bash}/bin/bash
      # Log mdadm events to journald
      # Arguments: event device component
      ${pkgs.util-linux}/bin/logger -t mdadm -p daemon.warning "RAID event: $1 on device $2 component $3"
    '';
  };

  environment.etc."mdadm.conf".text = ''
    PROGRAM /etc/mdadm-alert.sh
    MAILADDR root
  '';

  # NFS mount for media over WireGuard from wolf
  # Uses systemd.mounts instead of fileSystems so switch-to-configuration can
  # find the unit file (fileSystems + fstab-generator puts it in /run, which
  # the NixOS 25.11 Rust activator can't open).
  systemd.mounts = [
    {
      what = "10.10.0.1:/mnt/storage/media";
      where = "/mnt/media";
      type = "nfs";
      options = "nfsvers=4.2,soft,timeo=30,retrans=2,noatime,acregmin=60,acregmax=600,acdirmin=60,acdirmax=600";
      after = [
        "wireguard-wg0.service"
        "network-online.target"
      ];
      requires = [ "wireguard-wg0.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "remote-fs.target" ];
      mountConfig.TimeoutSec = "30s";
    }
  ];

  # Set NFS readahead to 16 MB after mount (default is 128 KB — too small for GB-sized media files)
  # The BDI (Backing Device Info) readahead controls how much the kernel prefetches ahead of reads,
  # directly reducing stalls when Jellyfin starts playing a new file.
  systemd.services.nfs-readahead = {
    description = "Set NFS readahead for media mount";
    after = [ "mnt-media.mount" ];
    requires = [ "mnt-media.mount" ];
    wantedBy = [ "mnt-media.mount" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "nfs-readahead" ''
        bdi=$(${pkgs.util-linux}/bin/findmnt -n -o MAJ:MIN /mnt/media | ${pkgs.coreutils}/bin/tr -d ' ')
        echo 16384 > /sys/class/bdi/"$bdi"/read_ahead_kb
      ''}";
    };
  };

  # TCP buffer tuning for NFS over WireGuard
  # Larger buffers fill the bandwidth-delay product, reducing stalls on sequential reads
  boot.kernel.sysctl = {
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.ipv4.tcp_rmem" = "4096 1048576 16777216";
    "net.ipv4.tcp_wmem" = "4096 1048576 16777216";
  };

  # Intel VA-API hardware transcoding support (Kaby Lake i7-7700K)
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
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
    "render" # Intel GPU access for VA-API transcoding
    "video" # Intel GPU access for VA-API transcoding
  ];
  systemd.services.jellyfin = {
    after = [ "mnt-media.mount" ];
    requires = [ "mnt-media.mount" ];
    serviceConfig = {
      SupplementaryGroups = [
        "media"
        "render"
        "video"
      ];
    };
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
      debugAuthLogging = true;
      transcodeDebugLogging = true;
      installPlaybackReportingPlugin = true;
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

      jellyfinExporter = {
        enable = true;
        jellyfinUrl = "http://127.0.0.1:8096";
        apiKeyFile = config.sops.secrets.jellyfin_api_key.path;
        enableActivityCollector = true;
      };

      jellyfinPlaycount = {
        enable = true;
        jellyfinUrl = "http://127.0.0.1:8096";
        apiKeyFile = config.sops.secrets.jellyfin_api_key.path;
        monitorAllUsers = true;
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
          {
            job_name = "jellyfin-exporter";
            static_configs = [
              {
                targets = [ "127.0.0.1:9594" ];
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
        extraScrapeConfigs = [
          {
            job_name = "jellyfin";
            static_configs = [
              {
                targets = [ "localhost" ];
                labels = {
                  job = "jellyfin";
                  host = "bear";
                  __path__ = "/var/lib/jellyfin/log/*.log";
                };
              }
            ];
          }
        ];
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
    jellyfin_api_key = {
      # jellyfin-exporter and jellyfin-playcount services run as DynamicUser
      mode = "0444";
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
