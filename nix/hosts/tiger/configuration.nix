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
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    supportedFilesystems = [ "zfs" ];
    binfmt.emulatedSystems = [
      "aarch64-linux"
      "armv7l-linux"
    ];
  };

  networking = {
    hostName = "tiger";
    hostId = "48661cc0";
    useDHCP = lib.mkDefault true;
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
        enable = false;
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
        sleep_between_channels = 180;

        # Conservative defaults - only check 5 most recent videos per channel
        max_videos_default = 5;
        max_videos_initial = 30; # First run gets more to populate archive
        download_shorts = false; # Global default: no shorts

        watched_channels = [
          # cycling
          "@BermPeakExpress"
          "@bike2reality814"
          "@BIKEPACKINGcom"
          "@BikePak"
          "@chadweberg1" # Chad Weberg
          "@ChumbaUSABikes"
          "@Cycling366"
          "@Danny_MacAskill"
          "@DirtyTeethMTB"
          "@duzer"
          "@DylanJohnsonCycling"
          "@EFProCycling"
          "@FarBeyond-EFPC"
          "@FullBeansCyclingCompany"
          "@howtheracewaswon"
          "@JackScottkeogh"
          "@jasperverkuijl"
          "@jjjjustin"
          "@joe.nation"
          "@joffreymaluski"
          "@joshibbett"
          "@justinasleveika"
          "@KDubzDidWhat"
          "@KeepSmilingAdventures"
          "@lesperitdelbikepacking"
          "@MickTurnbullFilms"
          "@msoleilblais74"
          "@omniumcargo"
          "@panoramacycles"
          "@PatrickMcGrady1"
          "@PaulComponentEngineering"
          "@pnwbikepacking"
          "@raphafilms"
          "@RideProductionsNZ"
          "@RousLigon"
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
          "@aaedmusa"
          "@BennettStirton"
          "@dkbuilds"
          "@lostartpress"
          "@MarkRober"
          "@matthiaswandel"
          "@Paul.Sellers"
          "@propdepartment"
          "@RexKrueger"
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
          "@theslappablejerk"
          "@treykennedy"
          "@whistlindiesel"

          # tech
          "@AdamJames-tv"
          "@KRAZAM"

          # outdoor
          "@bronandjacob"
          "@ChrisburkardStudio"
          "@courtneyevewhite"
          "@RabEquipment"
          "@theaudaciousreport"
        ];
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
          DATA_DIR = config.systemFoundry.youtubeDownloader.data_dir;
        };
        script = ''
          #!/usr/bin/env bash
          set -euo pipefail

          TOKEN=$(cat $TOKEN_FILE)
          TODAY="$(date +%Y-%m-%d)"
          TWO_DAYS_AGO="$(date -d "$TODAY - 2 days" +%Y-%m-%d)"
          WORKING_DIR="$DATA_DIR/yt-jelly-sync"
          echo "TODAY: $TODAY"
          echo "TWO_DAYS_AGO: $TWO_DAYS_AGO"
          echo "WORKING_DIR: $WORKING_DIR"

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

            temp_file=$(mktemp)
            fd --type=f --changed-before "$TWO_DAYS_AGO" . "$WORKING_DIR" -0 | xargs -0 -r ls -t1d > "$temp_file" 2>/dev/null || true
            old_vids_file=$(head -n1 "$temp_file" 2>/dev/null || true)
            rm -f "$temp_file"
            if ! [[ -f "$old_vids_file" ]]; then
              echo "Can not find an old enough file. We'll try again tomorrow."
              exit 0
            fi

            vids_to_remove=$(comm -12 "$WORKING_DIR/$TODAY.txt" "$old_vids_file")

          if [[ -z "$vids_to_remove" ]]; then
            echo "No videos to remove"
            exit 0
          fi

            echo "$vids_to_remove" | while read -r vid; do
              if [[ -f "$vid" ]]; then
                rm -v "$vid"
              else
                echo "Can not find $vid"
              fi
            done

            fd --type=directory --type=empty . /mnt/media/yt -X rmdir -v
            echo "Updating library"
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
