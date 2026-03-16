{
  config,
  pkgs,
  lib,
  ...
}:
let
  mediaGroup = "media";
  service_root = "/var/lib";
in
{
  imports = [ ./hardware-configuration.nix ];

  boot = {
    # Use the systemd-boot EFI boot loader.
    loader = {
      systemd-boot = {
        enable = true;
        configurationLimit = 20; # Keep only 20 generations in /boot
      };
      efi.canTouchEfiVariables = true;
    };
    supportedFilesystems = [
      "zfs"
      "nfs"
    ];
    binfmt.emulatedSystems = [
      "aarch64-linux"
      "armv7l-linux"
    ];
    # Disable legacy containers (conflicts with stateVersion < 22.05)
    enableContainers = false;
  };

  networking = {
    hostName = "tiger";
    hostId = "48661cc0";
    useDHCP = lib.mkDefault true;

    # WireGuard tunnel to wolf for NFS
    wireguard.interfaces.wg0 = {
      ips = [ "10.10.0.3/24" ];
      listenPort = 51820;
      privateKeyFile = config.sops.secrets.wireguard_private_key_tiger.path;
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

  services = {
    zfs = {
      autoScrub.enable = true;
      autoSnapshot.enable = false;
    };
    sanoid = {
      enable = true;
      extraArgs = [
        "--verbose"
        "--cron" # create snapshots, then purge expired ones
      ];
      datasets = {
        "storage/backups" = {
          autosnap = true;
          autoprune = true;

          # This share is for things I truly want backed up. In this context
          # backup is offside availability and not the ability to comb through
          # old archived copied. I do keep some yearly since storage is cheap,
          # but I'm not afraid to lower the longer tiers if needed to save some
          # space.
          hourly = 4;
          daily = 31;
          monthly = 24;
          yearly = 10;
        };
        "storage/photos" = {
          autosnap = true;
          autoprune = true;

          # My thoughts for the number and frequency of snapshots. The photos
          # that live on this zfs share are a 1:1 dump of my ~/photos directory
          # on my local laptop. If I ever need to not keep the entire library
          # local I need to revisit this. The backup here is more for a short
          # term disaster recovery, such as if I lose my local storage. I am
          # not worried about recovering a photo I deleted a long time ago.
          hourly = 0;
          daily = 8;
          monthly = 12;
          yearly = 0;
        };
      };
    };
    nix-serve = {
      enable = true;
    };
    openssh.ports = [ 2332 ];
    caddy = {
      enable = false;
      email = "kyle@ondy.org";
      globalConfig = ''
        http_port 9080
        https_port 9443
      '';
      virtualHosts = { };
    };
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 35d";
  };

  users = {
    # for backup reasons
    users = {
      "svc.backup" = {
        isSystemUser = true;
        group = "svc.backup";
        # todo: change and store with SOP
        hashedPassword = "$6$Yajq.T62wzgWLEGz$RYoSapIb3RBA.8cfolUlXsZG2p588jwjUFYHJLsAgoN3rSKuk6XE3dZiMOtJETP22EQNTHdrFvcpGyhNm.KL10";
      };
      "svc.syncoid" = {
        isNormalUser = true;
        group = "svc.backup";
        # todo: change and store with SOP
        hashedPassword = "$6$Yajq.T62wzgWLEGz$RYoSapIb3RBA.8cfolUlXsZG2p588jwjUFYHJLsAgoN3rSKuk6XE3dZiMOtJETP22EQNTHdrFvcpGyhNm.KL10";
        extraGroups = [ "wheel" ]; # TODO: figure out the exact permissions needed
        openssh.authorizedKeys.keys = [ ];
      };
    };
    groups."svc.backup".members = [
      "svc.backup"
      "kyle"
    ];
  };

  fileSystems = {
    "/mnt/scratch-fast" = {
      device = "scratch/scratch";
      fsType = "zfs";
      neededForBoot = false;
    };
    "/mnt/backups" = {
      device = "storage/backups";
      fsType = "zfs";
      neededForBoot = false;
    };
    "/mnt/data" = {
      device = "storage/data";
      fsType = "zfs";
      neededForBoot = false;
    };
    "/mnt/media" = {
      device = "storage/media";
      fsType = "zfs";
      neededForBoot = false;
    };
    "/mnt/scratch-big" = {
      device = "storage/scratch-big";
      fsType = "zfs";
      neededForBoot = false;
    };
    "/mnt/photos" = {
      device = "storage/photos";
      fsType = "zfs";
      neededForBoot = false;
    };
  };

  # NFS mount for wolf's media over WireGuard
  # Uses systemd.mounts instead of fileSystems so switch-to-configuration can
  # find the unit file (fileSystems + fstab-generator puts it in /run, which
  # the NixOS 25.11 Rust activator can't open).
  systemd.mounts = [
    {
      what = "10.10.0.1:/mnt/storage/media";
      where = "/mnt/wolf-media";
      type = "nfs";
      options = "nfsvers=4.2,soft,timeo=30,retrans=2";
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

  # media managment
  users.groups."${mediaGroup}".members = [
    config.systemFoundry.nzbget.user
    config.systemFoundry.bazarr.user
    config.systemFoundry.radarr.user
    config.systemFoundry.sonarr.user
    "svc.deploy"
    "kyle"
  ];
  systemFoundry =
    let
      domain = "apps.dmz.1ella.com";
      backup_path = "/mnt/backups/apps";
    in
    {
      nginxReverseProxy.acme = {
        email = "kyle@ondy.org";
        dnsProvider = "namecheap";
        credentialsSecret = "namecheap";
      };

      sonarr = {
        enable = false;
        group = mediaGroup;
        domainName = "sonarr.${domain}";
        provisionCert = true;
        backup = {
          enable = true;
          destinationPath = "${backup_path}/sonarr/";
        };
      };
      radarr = {
        enable = false;
        group = mediaGroup;
        domainName = "radarr.${domain}";
        provisionCert = true;
        backup = {
          enable = true;
          destinationPath = "${backup_path}/radarr/";
        };
      };
      bazarr = {
        enable = false;
        group = mediaGroup;
        domainName = "bazarr.${domain}";
        backup = {
          enable = true;
          destinationPath = "${backup_path}/bazarr/";
        };
      };
      nzbhydra2 = {
        enable = false;
        domainName = "nzbhydra.${domain}";
        provisionCert = true;
        backup = {
          enable = true;
          destinationPath = "${backup_path}/nzbhydra2/";
        };
      };
      nzbget = {
        enable = false;
        group = mediaGroup;
        domainName = "nzbget.${domain}";
        provisionCert = true;
        backup = {
          enable = true;
          destinationPath = "${backup_path}/nzbget/";
        };
      };
      # Monitoring stack configuration
      monitoringStack = {
        enable = true;

        # Enable ZFS exporter for storage monitoring
        zfsExporter.enable = true;

        # Enable node exporter for system metrics
        nodeExporter.enable = true;

        # nginxlogExporter disabled: nginx is not running on tiger (was enabled by jellyfin)
        nginxlogExporter.enable = false;

        # Send metrics to wolf's VictoriaMetrics instance
        vmagent = {
          enable = true;
          remoteWriteUrl = "https://metrics.apps.ondy.org/api/v1/write";
          bearerTokenFile = config.sops.secrets.monitoring_token_tiger.path;
          scrapeConfigs = [
            {
              job_name = "node";
              static_configs = [
                {
                  targets = [ "127.0.0.1:9100" ];
                  labels = {
                    host = "tiger";
                  };
                }
              ];
            }
            {
              job_name = "zfs";
              static_configs = [
                {
                  targets = [ "127.0.0.1:9134" ];
                  labels = {
                    host = "tiger";
                  };
                }
              ];
            }
          ];
        };

        # Send logs to wolf's Loki instance
        promtail = {
          enable = true;
          lokiUrl = "https://loki.apps.ondy.org/loki/api/v1/push";
          bearerTokenFile = config.sops.secrets.monitoring_token_tiger.path;
          extraLabels = {
            host = "tiger";
          };
        };
      };

    };

  hardware = {
    graphics = {
      enable = true;
      extraPackages = with pkgs; [
        # https://nixos.wiki/wiki/Accelerated_Video_Playback
        vpl-gpu-rt
        intel-media-driver # LIBVA_DRIVER_NAME=iHD
        libvdpau-va-gl
        # OpenCL filter support (hardware tonemapping and subtitle burn-in)
        intel-compute-runtime
        # To make OBS HW recording work
        # https://discourse.nixos.org/t/trouble-getting-quicksync-to-work-with-jellyfin/42275
      ];
    };
  };
  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "iHD";
  };

  sops.secrets = {
    namecheap = { };
    monitoring_token_tiger = {
      # vmagent service runs as DynamicUser, which means it can't be assigned
      # file ownership directly. Using mode 0444 allows the service to read it.
      # This is acceptable since the token is only used for authentication to
      # our own VictoriaMetrics instance, not external services.
      mode = "0444";
    };
    wireguard_private_key_tiger = {
      mode = "0400";
    };
  };

  system.stateVersion = "21.11"; # Did you read the comment?
}
