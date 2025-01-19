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
      virtualHosts = {
        "jellyfin.apps.home.1ella.com" = {
          extraConfig = ''
            reverse_proxy http://127.0.0.1:8096
          '';
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
      bazarr = {
        enable = true;
        group = mediaGroup;
        domainName = "bazarr.${domain}";
        backup = {
          enable = true;
          destinationPath = "${backup_path}/bazarr/";
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
      youtubeDownloader = {
        enable = true;
        media_dir = "/mnt/media/yt";
        temp_dir = "/mnt/scratch-big/youtube-downloads";
        watched_channels = [
          # cycling
          "@BermPeakExpress"
          "@bike2reality814"
          "@BIKEPACKINGcom"
          "@BikePak"
          "@blacklinecoaching6925"
          "@Buzzalong.cycling"
          "@chadweberg1" # Chad Weberg
          "@ChumbaUSABikes"
          "@Cycling366"
          "@Danny_MacAskill"
          "@DirtyTeethMTB"
          "@duzer"
          "@DylanJohnsonCycling"
          "@EFProCycling"
          "@FullBeansCyclingCompany"
          "@howtheracewaswon"
          "@JackScottkeogh"
          "@jasperverkuijl"
          "@joe.nation"
          "@joffreymaluski"
          "@joshibbett"
          "@JoyOfBike"
          "@KDubzDidWhat"
          "@KeepSmilingAdventures"
          "@lesperitdelbikepacking"
          "@MickTurnbullFilms"
          "@mikemono"
          "@msoleilblais74"
          "@nerocoaching" # "Jesse Coyle"
          "@nrmlmtber"
          "@omniumcargo"
          "@PatrickMcGrady1"
          "@PaulComponentEngineering"
          "@pnwbikepacking"
          "@raphafilms"
          "@SethsBikeHacks"
          "@sofianeshl"
          "@sportscientist" # Stephen Seiler
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

          # science
          "@miniminuteman773"
          "@Wendoverproductions"

          # maker
          "@lostartpress"
          "@MarkRober"
          "@matthiaswandel"
          "@Paul.Sellers"
          "@RexKrueger"
          "@RobCosmanWoodworking"
          "@StuffMadeHere"
          "@StuffMadeHere2"
          "@tested"
          "@theslowmoguys"
          "@TomStantonEngineering"
          "@WoodByWrightHowTo"

          # entertainment
          "@2MuchColinFurze"
          "@Ben_Brainard"
          "@CaptainDisillusion"
          "@CharlieBerens"
          "@colinfurze"
          "@DudeDad"
          "@GxAce"
          "@kaptainkristian"
          "@kurzgesagt"
          "@PracticalEngineeringChannel"
          "@RudyAyoub"
          "@SampsonBoatCo"
          "@ShubaMusic"
          "@theslappablejerk"
          "@treykennedy"

          # tech
          "@AdamJames-tv"
          "@ClojureTV"
          "@KRAZAM"

          # outdoor
          "@bronandjacob"
          "@ChrisburkardStudio"
          "@RabEquipment"
          "@theaudaciousreport"
        ];
      };
    };

  hardware = {
    graphics = {
      enable = true;
    };
  };

  # TODO: move to module if it works and I like it
  systemd = {
    services = {
      jellyfin-prune = {
        enable = true;
        startAt = "*-*-* 04:00:00"; # 4am
        path = with pkgs; [
          bashInteractive
          curl
          fd
          jq
        ];
        environment = {
          TOKEN_FILE = config.sops.secrets.jellyfin_api_token.path;
        };
        script = ''
          #!/usr/bin/env bash
          set -euo pipefail

          TOKEN=$(cat $TOKEN_FILE)
          TODAY="$(date +%Y-%m-%d)"
          TWO_DAYS_AGO="$(date -d "$TODAY - 2 days" +%Y-%m-%d)"
          WORKING_DIR="/tmp/yt-jelly-sync"

          print_watched_vids() {
            curl -sS -X 'GET' \
              'https://jellyfin.apps.dmz.1ella.com/Items?userId=8e521e5f-b1e2-479a-a57d-65a25b276504&recursive=true&parentId=2f958036-93af-1464-2fd4-a2bec23b34f5&fields=Path&enableUserData=true&enableTotalRecordCount=false&enableImages=false' \
              -H 'accept: application/json' \
              -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | jq -r '.Items[] | select(.UserData.PlayCount >= 1) | .Path'
          }

          update_lib() {
            curl -Ss -X 'POST' \
              'https://jellyfin.apps.dmz.1ella.com/ScheduledTasks/Running/7738148ffcd07979c7ceb148e06b3aed' \
              -H 'accept: */*' \
              -H "Authorization: MediaBrowser Token=\"$TOKEN\"" \
              -d ""
          }

          main() {
            vids=$(print_watched_vids)

            [[ -d "$WORKING_DIR" ]] || mkdir "$WORKING_DIR"
            echo "$vids" | sort > "$WORKING_DIR/$TODAY.txt"

            old_vids_file=$(fd --type=f . "$WORKING_DIR" | sort -r | sed -n "/$TWO_DAYS_AGO/,//p" | head -n1)
            if ! [[ -f "$old_vids_file" ]]; then
              echo "Can not find a file"
              exit 0
            fi

            vids_to_remove=$(comm -12 "$WORKING_DIR/$TODAY.txt" "$old_vids_file")

            [[ -z "$vids_to_remove" ]] && exit 0

            echo "$vids_to_remove" | while read -r vid; do
              if [[ -f "$vid" ]]; then
                rm -v "$vid"
              else
                echo "Can not find $vid"
              fi
            done

            fd --type=directory --type=empty . /mnt/media/yt -X rmdir
            update_lib
          }

          main
        '';
      };
    };
  };
  sops.secrets = {
    jellyfin_api_token = { };
  };

  system.stateVersion = "21.11"; # Did you read the comment?
}
