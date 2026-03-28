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

    # WireGuard tunnel for NFS
    wireguard.interfaces.wg0 = {
      ips = [ "10.10.0.1/24" ];
      listenPort = 51820;
      privateKeyFile = config.sops.secrets.wireguard_private_key_wolf.path;
      peers = [
        {
          # elk peer
          publicKey = "YBD4Si2FqaM0VxK0cvubNcDokXA2Uo1ymxjATg4GsEc=";
          allowedIPs = [ "10.10.0.4/32" ];
        }
      ];
    };

    firewall = {
      allowedUDPPorts = [ 51820 ]; # WireGuard
      interfaces.wg0 = {
        allowedTCPPorts = [
          2049 # NFS
          111 # NFS portmapper
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
  # Explicitly set GID to ensure consistency across NFS mounts
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
    # YouTube downloader media and temp directories
    "d /mnt/storage/media/yt 0775 root media -"
    "d /mnt/storage/downloads/youtube-temp 0755 root root -"
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
          enable = false;
          provisionCert = true;
          staticRoot = "/var/www/kyleondy.com";
          route53HostedZoneId = "Z0855021CRZ8TKMBC7EC";
        };

        # Redirect apex domain to www
        "kyleondy.com" = {
          enable = false;
          provisionCert = true;
          redirectTo = "www.kyleondy.com";
          route53HostedZoneId = "Z0855021CRZ8TKMBC7EC";
        };

        # Redirect ondy.org to www.kyleondy.com (requires DNS update to point to wolf)
        "ondy.org" = {
          enable = false;
          provisionCert = true;
          redirectTo = "www.kyleondy.com";
          # route53HostedZoneId not specified - lego will auto-detect the zone
        };

        # Default catch-all server that redirects to www.kyleondy.com
        "_" = {
          enable = false;
          isDefault = true;
          extraDomainNames = [ "www.kyleondy.com" ];
        };
      };
    };

    harmonia = {
      enable = false;
      domainName = "nix-cache.apps.ondy.org";
      provisionCert = true;
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

  };

  # NFS server - export media to elk over WireGuard
  services.nfs.server = {
    enable = true;
    nproc = 16; # Increase from default 8 to handle concurrent ops (playback + library scans + *arr activity)
    exports = ''
      /mnt/storage/media 10.10.0.4(ro,async,no_subtree_check,no_root_squash)
    '';
  };

  # TCP buffer tuning for NFS over WireGuard
  # Larger buffers fill the bandwidth-delay product, reducing stalls on sequential reads
  boot.kernel.sysctl = {
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.ipv4.tcp_rmem" = "4096 1048576 16777216";
    "net.ipv4.tcp_wmem" = "4096 1048576 16777216";
  };

  sops.secrets = {
    wireguard_private_key_wolf = {
      mode = "0400";
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
