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
    binfmt.emulatedSystems = [ "aarch64-linux" "armv7l-linux" ];
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
    apcupsd = {
      enable = true;
      # if power doesn't come on in 15 seconds, shutdown to preseve network
      # stack.
      # TODO: add hooks to shutdown POE pis
      configText = ''
        UPSTYPE usb
        NISIP 127.0.0.1
        TIMEOUT 15
      '';
    };
    zfs = {
      autoScrub.enable = true;
      autoSnapshot.enable = false;
    };
    sanoid = {
      enable = true;
      extraArgs = [
        "--verbose"
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
    samba = {
      enable = true;
      securityType = "user";
      extraConfig = ''
        workgroup = WORKGROUP
        server string = tiger
        netbios name = tiger
        security = user
        #use sendfile = yes
        #max protocol = smb2
        # note: localhost is the ipv6 localhost ::1
        hosts allow = 10.24.89. 127.0.0.1 localhost
        hosts deny = 0.0.0.0/0
        guest account = nobody
        #map to guest = bad user
      '';
      openFirewall = true;
      shares = {
        backups = {
          path = "/mnt/backups"; # todo: reference directly?
          browseable = "yes";
          "read only" = "no";
          "guest ok" = "no";
          "create mask" = "0644";
          "directory mask" = "0755";
          "force user" = "kyle";
          #"force group" = "groupname";
        };
        photos = {
          path = "/mnt/photos";
          browseable = "yes";
          "read only" = "no";
          "guest ok" = "no";
          "create mask" = "0644";
          "directory mask" = "0755";
          "force user" = "kyle";
          #"force group" = "groupname";
        };
      };
    };
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
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB+S8VkJTWt1220oiJJy/1O7Ih0BxGhY9O9l+y7XkDM3 root@alpha" # syncoid key on alpha
        ];
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
          enable = false; # not worth it, easy to set back up
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
        enable = false; # TODO: enable and expose
        domainName = "gitea.${domain}";
        backup = {
          # todo: backups were chewing through diskspace with mirrored repos
          enable = false;
          destinationPath = "${backup_path}/gitea/";
        };
      };
      binary_cache = {
        enable = false;
        domainName = "nix-cache.${domain}";
      };
      pixiecore = {
        enable = false;
        apiAddress = "http://localhost:3031"; # todo: reference api config
        listenPort = 3032;
      };
      nixNetbootServe = {
        enable = false;
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
      youtubeDownloader = {
        enable = true;
        media_dir = "/mnt/media/yt";
        temp_dir = "/mnt/scratch-big/youtube-downloads";
        watched_channels = [
          # cycling
          "@DylanJohnsonCycling"
          "@worstretirementever" # Phil Gaimon
          "@TheVCAdventures" # The Vegan Cyclist
          "@ValleyPreferredCyclingCenter"
          "@sportscientist" # Stephen Seiler
          "@blacklinecoaching6925"
          "@Danny_MacAskill"
          "@howtheracewaswon"
          "@JoyOfBike"
          "@chadweberg1" # Chad Weberg
          "@DirtyTeethMTB"
          "@jasperverkuijl"
          "@nerocoaching" # "Jesse Coyle"
          "@joe.nation"
          "@joshibbett"
          "@sofianeshl"
          "@TENTISTHENEWRENT"
          "@JackScottkeogh"
          "@PaulComponentEngineering"
          "@TurnCycling"
          "@duzer"
          "@KeepSmilingAdventures"
          "@EFProCycling"
          "@wattwagon"
          "@Buzzalong.cycling"
          "@BIKEPACKINGcom"
          "@mikemono"
          "@tristantakevideo"
          "@msoleilblais74"
          "@SethsBikeHacks"
          "@ChumbaUSABikes"
          "@BermPeakExpress"
          "@pnwbikepacking"
          "@nrmlmtber"

          # science
          "@Wendoverproductions"
          "@miniminuteman773"

          # maker
          "@tested"
          "@StuffMadeHere"
          "@StuffMadeHere2"
          "@StumpyNubs"

          # entertainment
          "@kaptainkristian"
          "@kurzgesagt"
          "@PracticalEngineeringChannel"
          "@SampsonBoatCo"
          "@ShubaMusic"
          "@GxAce"
          "@CharlieBerens"
          "@DudeDad"
          "@treykennedy"
          "@Ben_Brainard"
          "@CaptainDisillusion"
          "@colinfurze"
          "@2MuchColinFurze"
          "@theslappablejerk"
          "@RudyAyoub"
          "@yeahmadtv"

          # tech
          "@AdamJames-tv"
          "@ClojureTV"
          "@KRAZAM"
        ];
      };
    };

  nixpkgs.config.packageOverrides = pkgs: {
    vaapiIntel = pkgs.vaapiIntel.override { enableHybridCodec = true; };
  };
  hardware.opengl = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver # LIBVA_DRIVER_NAME=iHD
      vaapiIntel # LIBVA_DRIVER_NAME=i965 (older but works better for Firefox/Chromium)
      vaapiVdpau
      libvdpau-va-gl
    ];
  };

  # TODO: move to module if it works and I like it
  systemd = {
    services = {
      nix-update-and-build = {
        enable = false;
        startAt = "*-*-* 04:00:00"; # 4am
        path = with pkgs; [
          bash
          git
          gnumake
          jq
          nix
          nixos-rebuild
        ];
        script = ''
          set -ex
          cd $(mktemp -d)
          git clone https://github.com/kyleondy/dotfiles.git .
          cp flake.lock flake.lock.old
          make update
          cp flake.lock flake.lock.new
          hosts=$(nix flake show --json | jq -r '.nixosConfigurations | keys[]' | grep -v sd_card)
          for host in $hosts; do
            cp flake.lock.old flake.lock
            nice -n19 make HOSTNAME="$host" build
            orig_hash=$(readlink -f ./result)

            cp flake.lock.new flake.lock
            nice -n19 make HOSTNAME="$host" build
            echo "$host,$orig_hash,$(readlink -f ./result)" >> builds.csv
          done
          cp builds.csv /tmp/builds_$(date +%Y-%m-%d).csv
        '';
      };
    };
  };

  system.stateVersion = "21.11"; # Did you read the comment?
}

