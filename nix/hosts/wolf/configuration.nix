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
  };

  time.timeZone = "America/New_York";
  i18n = {
    defaultLocale = "en_US.UTF-8";
    extraLocaleSettings = {
      LC_ALL = "en_US.UTF-8";
    };
  };

  # Enable ZFS support
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;

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

  # Monitoring stack configuration
  systemFoundry = {
    monitoringStack = {
      enable = true;

      # Agent components that report to cheetah
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
        # Send metrics to cheetah's VictoriaMetrics
        remoteWriteUrl = "https://metrics.apps.ondy.org/api/v1/write";
        bearerTokenFile = config.sops.secrets.monitoring_token_wolf.path;
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
        ];
      };

      promtail = {
        enable = true;
        # Send logs to cheetah's Loki
        lokiUrl = "https://loki.apps.ondy.org/loki/api/v1/push";
        bearerTokenFile = config.sops.secrets.monitoring_token_wolf.path;
        extraLabels = {
          host = "wolf";
        };
      };
    };
  };

  # SOPS secrets
  sops.secrets = {
    monitoring_token_wolf = {
      # vmagent and promtail services run as DynamicUser, which means they can't be assigned
      # file ownership directly. Using mode 0444 allows the services to read it.
      mode = "0444";
    };
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.05";
}
