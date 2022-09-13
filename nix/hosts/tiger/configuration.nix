{ config, pkgs, ... }:
let
  mediaGroup = "media";
  service_root = "/var/lib";
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
    samba = {
      enable = true;
      openFirewall = true;
      shares = {
        backups = {
          path = "/mnt/backups"; # todo: reference directly?
          browseable = "yes";
          "read only" = "no";
          "guest ok" = "no";
          "valid_users" = "svc.backup";
          "create mask" = "0644";
          "directory mask" = "0755";
          # todo: force sounds bad
          "force user" = "svc.backup";
          "force group" = "svc.backup";
          #"force user" = "svc.backup";
          #"write list" = "
        };
      };
    };
  };
  users = {
    # for backup reasons
    users."svc.backup" = {
      isSystemUser = true;
      group = "svc.backup";
      # todo: change and store with SOP
      hashedPassword = "$6$Yajq.T62wzgWLEGz$RYoSapIb3RBA.8cfolUlXsZG2p588jwjUFYHJLsAgoN3rSKuk6XE3dZiMOtJETP22EQNTHdrFvcpGyhNm.KL10";
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

  # media managment
  users.groups."${mediaGroup}".members = [
    config.systemFoundry.jellyfin.user
    config.systemFoundry.nzbget.user
    config.systemFoundry.radarr.user
    config.systemFoundry.sonarr.user
    "svc.deploy" # todo
    "kyle"
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
      pixiecore = {
        enable = true;
        apiAddress = "http://localhost:3031"; # todo: reference api config
        listenPort = 3032;
      };
      nixNetbootServe = {
        enable = true;
        gcRootDir = "${service_root}/nix-netboot-serve/gc-roots";
        # todo: point to dotfiles?
        configurationDir = "${service_root}/nix-netboot-serve/configurations";
        profileDir = "${service_root}/nix-netboot-serve/profiles";
        cpioCacheDir = "${service_root}/nix-netboot-serve/cpio-cache";
        listenHost = "127.0.0.1"; # todo: localhost doesn't work
        listenPort = 3030;
      };
      pxe-api = {
        enable = false;
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
          "${config.systemFoundry.binary_cache.domainName}" = "10.25.89.5";
        };
        domainRecords = {
          "lan.509ely.com" = "10.25.89.1";
        };
      };
    };

  system.stateVersion = "21.11"; # Did you read the comment?
}

