{ config, pkgs, ... }:
let
  mediaGroup = "media";
in
{
  imports = [ ./hardware-configuration.nix ];

  boot = {
    # Use the systemd-boot EFI boot loader.
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    supportedFilesystems = [ "zfs" ];
    binfmt.emulatedSystems = [ "aarch64-linux" ];
  };

  networking = {
    hostName = "tiger";
    hostId = "48661cc0";
    interfaces = {
      enp6s0.useDHCP = true;
      enp7s0.useDHCP = true;
    };
  };

  services = {
    zfs = {
      autoScrub.enable = true;

      # todo: figure out my plan. There is `sanoid` which looks worth digging
      #       into.
      autoSnapshot.enable = false;
    };
    nix-serve = {
      enable = true;
    };
    openssh.ports = [ 2332 ];
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
  };

  # media managment
  users.groups."${mediaGroup}".members = [
    config.systemFoundry.jellyfin.user
    config.systemFoundry.nzbget.user
    config.systemFoundry.radarr.user
    config.systemFoundry.sonarr.user
    "svc.deploy" # todo
  ];
  systemFoundry =
    let
      domain = "apps.dmz.509ely.com";
      backup_path = "/mnt/backups/apps";
    in
    {
      sonarr = {
        enable = true;
        group = mediaGroup;
        domainName = "sonarr.${domain}";
        backup = {
          enable = true;
          destinationPath = "${backup_path}/sonarr/";
        };
      };
      radarr = {
        enable = true;
        group = mediaGroup;
        domainName = "radarr.${domain}";
        backup = {
          enable = true;
          destinationPath = "${backup_path}/radarr/";
        };
      };
      jellyfin = {
        enable = true;
        group = mediaGroup;
        domainName = "jellyfin.${domain}";
        backup = {
          enable = true;
          destinationPath = "${backup_path}/jellyfin/";
        };
      };
      nzbhydra2 = {
        enable = true;
        domainName = "nzbhydra.${domain}";
        backup = {
          enable = true;
          destinationPath = "${backup_path}/nzbhydra2/";
        };
      };
      nzbget = {
        enable = true;
        group = mediaGroup;
        domainName = "nzbget.${domain}";
        backup = {
          enable = true;
          destinationPath = "${backup_path}/nzbget/";
        };
      };
      gitea = {
        enable = true;
        domainName = "gitea.${domain}";
        backup = {
          # todo: backups were chewing through diskspace with mirrored repos
          enable = false;
          destinationPath = "${backup_path}/gitea/";
        };
      };
      binary_cache = {
        enable = true;
        domainName = "nix-cache.${domain}";
      };
      # todo: spin up a dmz_util server and move this
      dnsServer = {
        enable = true;
        blacklist.enable = true;
        upstreamDnsServers = [ "10.25.89.1" ];
        aRecords = {
          "gitea.apps.dmz.509ely.com" = "10.25.89.5";
          "jellyfin.apps.dmz.509ely.com" = "10.25.89.5";
          "nzbget.apps.dmz.509ely.com" = "10.25.89.5";
          "nzbhydra.apps.dmz.509ely.com" = "10.25.89.5";
          "radarr.apps.dmz.509ely.com" = "10.25.89.5";
          "sonarr.apps.dmz.509ely.com" = "10.25.89.5";
          "nix-cache.apps.dmz.509ely.com" = "10.25.89.5";
        };
        domainRecords = {
          "lan.509ely.com" = "10.25.89.1";
        };
      };
    };

  system.stateVersion = "21.11"; # Did you read the comment?
}

