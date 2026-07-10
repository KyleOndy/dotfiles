{
  config,
  pkgs,
  lib,
  ...
}:
let
  mediaGroup = "media";
  service_root = "/var/lib";

  # Local Alertmanager endpoint; NUT pushes UPS events here so they email out
  # the same way as every other monitoring alert.
  amUrl = "http://${config.systemFoundry.monitoringStack.alertmanager.listenAddress}:${toString config.systemFoundry.monitoringStack.alertmanager.port}/api/v2/alerts";

  # Dispatcher for upssched: fires alerts on line-state changes and forces the
  # shutdown when the 20s timer expires. Runs as root (upsmon runs as root).
  upsSchedCmd = pkgs.writeShellScript "upssched-cmd" ''
    set -eu

    now=$(${pkgs.coreutils}/bin/date -u +%Y-%m-%dT%H:%M:%SZ)

    post() {
      ${pkgs.curl}/bin/curl -sS -m 10 -X POST \
        -H 'Content-Type: application/json' \
        -d "$1" "${amUrl}" || true
    }

    case "$1" in
      onbatt-notify)
        post '[{"labels":{"alertname":"UPSOnBattery","severity":"warning","host":"tiger","ups":"tiger"},"annotations":{"summary":"tiger UPS on battery (mains power lost)","description":"Running on battery. tiger shuts down in 20s to extend runtime for the attached network gear; the UPS itself stays on."},"startsAt":"'"$now"'"}]'
        ;;
      online-notify)
        post '[{"labels":{"alertname":"UPSOnBattery","severity":"warning","host":"tiger","ups":"tiger"},"annotations":{"summary":"tiger UPS on battery (mains power lost)"},"endsAt":"'"$now"'"}]'
        ;;
      lowbatt-notify)
        post '[{"labels":{"alertname":"UPSLowBattery","severity":"critical","host":"tiger","ups":"tiger"},"annotations":{"summary":"tiger UPS battery low","description":"UPS battery is nearly depleted; attached gear will lose power soon."},"startsAt":"'"$now"'"}]'
        ;;
      shutdown)
        ${pkgs.util-linux}/bin/logger -t upssched \
          "UPS on battery for 20s, forcing shutdown"
        ${pkgs.nut}/sbin/upsmon -c fsd
        ;;
    esac
  '';
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
    # Immich library lives on its own dataset rather than sharing storage/photos
    # with the laptop dump, so it stays out of that dataset's snapshot policy.
    # Create the dataset once on the host: zfs create -o mountpoint=legacy storage/immich
    "/mnt/immich" = {
      device = "storage/immich";
      fsType = "zfs";
      neededForBoot = false;
    };
  };

  # media managment
  users.groups."${mediaGroup}".members = [
    config.systemFoundry.sabnzbd.user
    config.systemFoundry.bazarr.user
    config.systemFoundry.radarr.user
    config.systemFoundry.sonarr.user
    config.systemFoundry.lidarr.user
    "jellyfin"
    "svc.deploy"
    "kyle"
  ];

  # Media/download directory layout. The library lives on /mnt/media and
  # downloads on /mnt/scratch-big. No /mnt/storage compat symlinks needed.
  # Downloads land on a different dataset than the library, so imports copy
  # rather than hardlink.
  systemd.tmpfiles.rules = [
    # svc.deploy owns so it can set timestamps via rsync; caddy group for serving.
    "d /var/www/kyleondy.com 0775 svc.deploy caddy -"
    "d /var/www/cogsworth.ondy.org 0775 svc.deploy caddy -"
    # Library subdirs missing on tiger (movies/tv already exist)
    "d /mnt/media/music 2775 root ${mediaGroup} -"
    "d /mnt/media/books 2775 root ${mediaGroup} -"
    # Real download tree on scratch-big (matches SABnzbd categories)
    "d /mnt/scratch-big/downloads 0755 root ${mediaGroup} -"
    "d /mnt/scratch-big/downloads/incomplete 0775 sabnzbd ${mediaGroup} -"
    "d /mnt/scratch-big/downloads/complete 0775 root ${mediaGroup} -"
    "d /mnt/scratch-big/downloads/complete/movies 0775 root ${mediaGroup} -"
    "d /mnt/scratch-big/downloads/complete/tv 0775 root ${mediaGroup} -"
    "d /mnt/scratch-big/downloads/complete/music 0775 root ${mediaGroup} -"
    "d /mnt/scratch-big/downloads/complete/books 0775 root ${mediaGroup} -"
  ];
  # Allow svc.deploy to write to the website directory (rsync content push).
  users.users."svc.deploy".extraGroups = [ "caddy" ];

  users.users.jellyfin.extraGroups = [
    mediaGroup
    "render" # Intel GPU access for VA-API/QSV transcoding
    "video" # Intel GPU access for VA-API/QSV transcoding
  ];
  systemd.services.jellyfin.serviceConfig.SupplementaryGroups = [
    mediaGroup
    "render"
    "video"
  ];

  # ---------------------------------------------------------------------------
  # UPS monitoring, automatic shutdown, and power-loss alerts
  # (Tripp Lite, USB 09ae:2012)
  #
  # NUT runs the driver + upsd locally and upsmon watches the line status.
  #
  #   * On mains loss, upssched immediately pushes a "UPS on battery" alert to
  #     the local Alertmanager (emailed like every other alert) and starts a
  #     20s timer.
  #   * If power returns first, the alert resolves and the timer is cancelled.
  #   * If power is still out at 20s, tiger shuts down cleanly. Shedding tiger's
  #     load lets the attached network gear ride the UPS battery for longer.
  #   * killpower is left OFF (POWERDOWNFLAG = null): tiger powers off but the
  #     UPS keeps running, so the network gear stays online until the battery
  #     is exhausted. Trade-off: tiger will NOT auto-restart after a short
  #     outage (its PSU never loses power). It comes back only after a full
  #     battery drain (UPS cuts out) then mains return, with BIOS "restore on
  #     AC power loss" enabled.
  # ---------------------------------------------------------------------------
  power.ups = {
    enable = true;
    mode = "standalone";

    # upsmon runs as root so the upssched command script can force the shutdown
    # (upsmon -c fsd) without a privilege dance. Single-admin host, so this is
    # an acceptable simplification.
    upsmon.user = "root";

    ups.tiger = {
      driver = "usbhid-ups";
      port = "auto";
      description = "Tripp Lite (tiger)";
      # Bind to this exact device so the driver never grabs another HID gadget.
      directives = [
        "vendorid = 09ae"
        "productid = 2012"
      ];
    };

    # Local monitor account. The password only guards loopback access to upsd,
    # so it is generated on the host at boot (nut-genpass below) rather than
    # stored in sops.
    users.upsmon = {
      passwordFile = "/var/lib/nut/monpass";
      upsmon = "primary";
    };

    upsmon.monitor.tiger = {
      system = "tiger@localhost";
      user = "upsmon";
      type = "primary";
    };

    upsmon.settings = {
      # Fire the NOTIFYCMD (upssched) on these events so it can alert and
      # start/cancel the timer. Without EXEC upsmon only logs them.
      NOTIFYFLAG = [
        [
          "ONBATT"
          "SYSLOG+EXEC"
        ]
        [
          "ONLINE"
          "SYSLOG+EXEC"
        ]
        [
          "LOWBATT"
          "SYSLOG+EXEC"
        ]
      ];
      # Keep the UPS powered after tiger shuts down (network gear stays online).
      POWERDOWNFLAG = null;
    };

    schedulerRules = "${pkgs.writeText "upssched.conf" ''
      CMDSCRIPT ${upsSchedCmd}
      PIPEFN /run/nut/upssched.pipe
      LOCKFN /run/nut/upssched.lock
      # Alert immediately on mains loss, and start the shutdown countdown.
      AT ONBATT * EXECUTE onbatt-notify
      AT ONBATT * START-TIMER shutdown 20
      # Power restored: clear the alert and cancel the shutdown.
      AT ONLINE * EXECUTE online-notify
      AT ONLINE * CANCEL-TIMER shutdown
      # Battery nearly empty: last-warning alert.
      AT LOWBATT * EXECUTE lowbatt-notify
    ''}";
  };

  # Generate the loopback-only upsd/upsmon password once, before either daemon
  # starts. Kept out of the Nix store (world-readable) and out of sops.
  systemd.services.nut-genpass = {
    description = "Generate local NUT monitor password";
    wantedBy = [ "multi-user.target" ];
    before = [
      "upsd.service"
      "upsmon.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      install -d -m0700 /var/lib/nut
      if [ ! -s /var/lib/nut/monpass ]; then
        umask 077
        ${pkgs.openssl}/bin/openssl rand -hex 24 > /var/lib/nut/monpass
      fi
    '';
  };
  systemd.services.upsd = {
    after = [ "nut-genpass.service" ];
    requires = [ "nut-genpass.service" ];
  };
  systemd.services.upsmon = {
    after = [ "nut-genpass.service" ];
    requires = [ "nut-genpass.service" ];
  };

  systemFoundry =
    let
      backup_path = "/mnt/backups/apps";
    in
    {
      nginxReverseProxy.acme = {
        email = "kyle@ondy.org";
        dnsProvider = "namecheap";
        credentialsSecret = "namecheap";
      };

      caddyReverseProxy = {
        enable = true;
        infraDomain = "tiger.infra.ondy.org";
        acme = {
          email = "kyle@ondy.org";
          credentialsSecret = "apps_ondy_org_route53";
        };
        # Public apps.ondy.org aliases for the migrated stack. Each gets its own
        # vhost + individual cert via Route53 DNS-01.
        sites = {
          "sonarr.tiger.infra.ondy.org".publicAliases = [ "sonarr.apps.ondy.org" ];
          "radarr.tiger.infra.ondy.org".publicAliases = [ "radarr.apps.ondy.org" ];
          "lidarr.tiger.infra.ondy.org".publicAliases = [ "lidarr.apps.ondy.org" ];
          "bazarr.tiger.infra.ondy.org".publicAliases = [ "bazarr.apps.ondy.org" ];
          "prowlarr.tiger.infra.ondy.org".publicAliases = [ "prowlarr.apps.ondy.org" ];
          "sabnzbd.tiger.infra.ondy.org".publicAliases = [ "sabnzbd.apps.ondy.org" ];
          "jellyseerr.tiger.infra.ondy.org".publicAliases = [ "jellyseerr.apps.ondy.org" ];
          "navidrome.tiger.infra.ondy.org".publicAliases = [ "navidrome.apps.ondy.org" ];
          "jellyfin.tiger.infra.ondy.org".publicAliases = [ "jellyfin.apps.ondy.org" ];
          "immich.tiger.infra.ondy.org".publicAliases = [
            "immich.apps.ondy.org"
            "photos.ondy.org"
          ];

          # Monitoring stack public aliases. Each gets its own
          # vhost + individual cert via Route53 DNS-01.
          "grafana.tiger.infra.ondy.org".publicAliases = [ "grafana.apps.ondy.org" ];
          "loki.tiger.infra.ondy.org".publicAliases = [ "loki.apps.ondy.org" ];
          "metrics.tiger.infra.ondy.org".publicAliases = [ "metrics.apps.ondy.org" ];
          "vmalert.tiger.infra.ondy.org".publicAliases = [ "vmalert.apps.ondy.org" ];

          # Individual certs in the kyleondy.com and ondy.org zones via Route53 DNS-01.
          "www.kyleondy.com" = {
            enable = true;
            staticRoot = "/var/www/kyleondy.com";
          };
          # Cogsworth SMS compliance/landing site (source in the cogsworth repo,
          # rsynced via `make site-deploy`). Public host on tiger, not the Pi.
          "cogsworth.ondy.org" = {
            enable = true;
            staticRoot = "/var/www/cogsworth.ondy.org";
          };
          "kyleondy.com" = {
            enable = true;
            redirectTo = "www.kyleondy.com";
          };
          "ondy.org" = {
            enable = true;
            redirectTo = "www.kyleondy.com";
          };
          "_" = {
            enable = true;
            isDefault = true;
            extraDomainNames = [ "www.kyleondy.com" ];
          };
        };
      };

      # The bare apexes can't follow the dynamic home WAN IP via DNS alone, so push
      # the live IP straight into their A records on a timer. www and *.apps stay
      # CNAMEs to tiger.infra; only the two apexes are managed here.
      ddnsRoute53 = {
        enable = true;
        credentialsSecretPath = config.sops.secrets.tiger_ddns_route53.path;
        records = [
          {
            zoneId = "Z0365859SHHFAPNR0QXN"; # ondy.org
            name = "ondy.org";
          }
          {
            zoneId = "Z0855021CRZ8TKMBC7EC"; # kyleondy.com
            name = "kyleondy.com";
          }
        ];
      };

      jellyfin = {
        enable = true;
        group = mediaGroup;
        domainName = "jellyfin.tiger.infra.ondy.org";
        transcodeDebugLogging = true;
        installPlaybackReportingPlugin = true;
        # jellyfin_api_key secret authenticates the backup + exporter.
        backup = {
          enable = true;
          apiKeyFile = config.sops.secrets.jellyfin_api_key.path;
        };

        # Intel Arc A380 (QSV via VPL). renderD128 + OpenCL tone mapping verified
        # with vainfo/clinfo. AllowAv1Encoding leans on the Arc's AV1 encoder.
        hardwareAcceleration = {
          enable = true;
          type = "qsv";
          device = "/dev/dri/renderD128";
        };
      };

      # *.tiger.infra.ondy.org wildcard cert covers all — no provisionCert needed.
      sonarr = {
        enable = true;
        group = mediaGroup;
        domainName = "sonarr.tiger.infra.ondy.org";
        backup = {
          enable = true;
          destinationPath = "${backup_path}/sonarr/";
        };
      };
      radarr = {
        enable = true;
        group = mediaGroup;
        domainName = "radarr.tiger.infra.ondy.org";
        backup = {
          enable = true;
          destinationPath = "${backup_path}/radarr/";
        };
      };
      lidarr = {
        enable = true;
        group = mediaGroup;
        domainName = "lidarr.tiger.infra.ondy.org";
        backup = {
          enable = true;
          destinationPath = "${backup_path}/lidarr/";
        };
      };
      bazarr = {
        enable = true;
        group = mediaGroup;
        domainName = "bazarr.tiger.infra.ondy.org";
        backup = {
          enable = true;
          destinationPath = "${backup_path}/bazarr/";
        };
      };
      prowlarr = {
        enable = true;
        group = mediaGroup;
        domainName = "prowlarr.tiger.infra.ondy.org";
      };
      sabnzbd = {
        enable = true;
        group = mediaGroup;
        domainName = "sabnzbd.tiger.infra.ondy.org";
      };
      jellyseerr = {
        enable = true;
        domainName = "jellyseerr.tiger.infra.ondy.org";
      };
      navidrome = {
        enable = true;
        domainName = "navidrome.tiger.infra.ondy.org";
        musicFolder = "/mnt/media/music";
      };
      immich = {
        enable = true;
        domainName = "immich.tiger.infra.ondy.org";
        # Dedicated dataset (storage/immich) mounted at /mnt/immich, kept out of
        # the storage/photos snapshot policy. Overrides the module default of
        # After a DB restore, run `immich-admin change-media-location` to rewrite
        # absolute paths from /mnt/storage/photos to /mnt/immich.
        mediaLocation = "/mnt/immich";
        # provisionCert not needed — covered by the *.tiger.infra.ondy.org wildcard cert
      };

      # Monitoring stack configuration. tiger is the central server running
      # VictoriaMetrics/Loki/Grafana/Alertmanager/vmalert; also scrapes itself.
      monitoringStack = {
        enable = true;
        domain = "tiger.infra.ondy.org";
        monitoringBasicAuth = config.sops.secrets.monitoring_basicauth.path;

        retention = {
          metrics = 400; # days
          logs = 400; # days
        };

        # Server-side components (central monitoring server)
        victoriametrics.enable = true;
        loki.enable = true;
        # Loki refuses loopback for the ring instance address, so "lo" alone
        # isn't usable -- it needs tiger's real NIC or it dies with
        # "no useable address found for interfaces".
        loki.instanceInterfaceNames = [
          "enp10s0"
          "lo"
        ];
        grafana.enable = true;
        alertmanager.enable = true;
        vmalert.enable = true;

        # Enable ZFS exporter for storage monitoring
        zfsExporter.enable = true;

        # Enable node exporter for system metrics
        nodeExporter.enable = true;

        # nginxlogExporter disabled: nginx is not running on tiger (was enabled by jellyfin)
        nginxlogExporter.enable = false;

        jellyfinExporter = {
          enable = true;
          jellyfinUrl = "http://127.0.0.1:8096";
          apiKeyFile = config.sops.secrets.jellyfin_api_key.path;
          enableActivityCollector = true;
        };

        # Exportarr for *arr + sabnzbd metrics. API keys come from sops.
        exportarr = {
          enable = true;
          sonarr = {
            enable = true;
            apiKeyFile = config.sops.secrets.sonarr_api_key.path;
          };
          radarr = {
            enable = true;
            apiKeyFile = config.sops.secrets.radarr_api_key.path;
          };
          lidarr = {
            enable = true;
            apiKeyFile = config.sops.secrets.lidarr_api_key.path;
            enableAdditionalMetrics = false;
          };
          prowlarr = {
            enable = true;
            apiKeyFile = config.sops.secrets.prowlarr_api_key.path;
          };
          bazarr = {
            enable = true;
            apiKeyFile = config.sops.secrets.bazarr_api_key.path;
          };
          sabnzbd = {
            enable = true;
            apiKeyFile = config.sops.secrets.sabnzbd_api_key.path;
          };
        };

        # Scrape local exporters into the now-local VictoriaMetrics instance.
        vmagent = {
          enable = true;
          remoteWriteUrl = "http://127.0.0.1:8428/api/v1/write";
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
            {
              job_name = "exportarr-sonarr";
              static_configs = [
                {
                  targets = [ "127.0.0.1:9707" ];
                  labels = {
                    host = "tiger";
                  };
                }
              ];
            }
            {
              job_name = "exportarr-radarr";
              static_configs = [
                {
                  targets = [ "127.0.0.1:9708" ];
                  labels = {
                    host = "tiger";
                  };
                }
              ];
            }
            {
              job_name = "exportarr-lidarr";
              scrape_interval = "60s";
              scrape_timeout = "30s";
              static_configs = [
                {
                  targets = [ "127.0.0.1:9709" ];
                  labels = {
                    host = "tiger";
                  };
                }
              ];
            }
            {
              job_name = "exportarr-prowlarr";
              static_configs = [
                {
                  targets = [ "127.0.0.1:9711" ];
                  labels = {
                    host = "tiger";
                  };
                }
              ];
            }
            {
              job_name = "exportarr-bazarr";
              static_configs = [
                {
                  targets = [ "127.0.0.1:9712" ];
                  labels = {
                    host = "tiger";
                  };
                }
              ];
            }
            {
              job_name = "exportarr-sabnzbd";
              static_configs = [
                {
                  targets = [ "127.0.0.1:9713" ];
                  labels = {
                    host = "tiger";
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
                    host = "tiger";
                  };
                }
              ];
            }
          ];
        };

        # Ship logs to the now-local Loki instance.
        promtail = {
          enable = true;
          lokiUrl = "http://127.0.0.1:3100/loki/api/v1/push";
          extraLabels = {
            host = "tiger";
          };
        };
      };

      ytdlSub = {
        enable = false;
        media_dir = "/mnt/media/yt";
        temp_dir = "/mnt/media/yt-temp";
        # data_dir left at default (/var/lib/ytdl-sub/youtube) so yt-push-cookies path matches

        tiers = {
          # Frequent posters: checked daily, limited to 10 videos to reduce request volume
          daily = {
            schedule = "*-*-* 15:00:00";
            max_videos = 10;
          };
          # Everything else: checked weekly, higher video limit for catch-up
          weekly = {
            schedule = "Mon *-*-* 15:00:00";
            max_videos = 20;
          };
        };

        # No source_address / wireguard_service — tiger exits via its native home IP.

        channels = {
          Cycling = [
            "@BeauMiles"
            "@BermPeakExpress"
            "@bike2reality814"
            "@BIKEPACKINGcom"
            "@BikePak"
            "@chadweberg1" # Chad Weberg
            "@ChumbaUSABikes"
            "@Cycling366"
            {
              name = "@Danny_MacAskill";
              tier = "daily";
            }
            {
              name = "@DirtyTeethMTB";
              tier = "daily";
            }
            "@duzer"
            "@DylanJohnsonCycling"
            "@EFProCycling"
            {
              name = "@FarBeyond-EFPC";
              tier = "daily";
            }
            {
              name = "@FullBeansCyclingCompany";
              tier = "daily";
            }
            "@hennapalosaari_"
            "@howtheracewaswon"
            "@JackScottkeogh"
            "@jasperverkuijl"
            "@jjjjustin"
            "@joe.nation"
            "@joffreymaluski"
            "@joshibbett"
            "@justinasleveika"
            "@katrinahase"
            "@KDubzDidWhat"
            "@KeepSmilingAdventures"
            {
              name = "@lesperitdelbikepacking";
              tier = "daily";
            }
            "@MediocreAmateur"
            "@MickTurnbullFilms"
            "@msoleilblais74"
            "@omniumcargo"
            "@panoramacycles"
            "@PatrickMcGrady1"
            "@PaulComponentEngineering"
            "@pnwbikepacking"
            {
              name = "@raphafilms";
              tier = "daily";
            }
            "@RideProductionsNZ"
            "@RousLigon"
            "@SethsBikeHacks"
            "@sofianeshl"
            "@sportscientist" # Stephen Seiler
            "@stephanwieser"
            {
              name = "@TailfinCycling";
              tier = "daily";
            }
            "@TENTISTHENEWRENT"
            {
              name = "@the_dirtbags";
              tier = "daily";
            }
            "@themountainraces"
            {
              name = "@TheVCAdventures";
              tier = "daily";
            } # The Vegan Cyclist
            "@tristanbogaard"
            "@tristantakevideo"
            "@TurnCycling"
            "@ValleyPreferredCyclingCenter"
            "@wattwagon"
            "@wheelstowaves"
            {
              name = "@worstretirementever";
              tier = "daily";
            } # Phil Gaimon
          ];
          Science = [
            "@AlphaPhoenixChannel"
            "@BetaPhoenixChannel"
            "@miniminuteman773"
          ];
          Maker = [
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
          ];
          Entertainment = [
            "@2MuchColinFurze"
            "@Ben_Brainard"
            "@CaptainDisillusion"
            {
              name = "@CharlieBerens";
              tier = "daily";
            }
            "@colinfurze"
            "@DudeDad"
            {
              name = "@Gossip.Goblin";
              tier = "daily";
            }
            "@GxAce"
            "@kaptainkristian"
            "@kurzgesagt"
            "@PracticalEngineeringChannel"
            "@RudyAyoub"
            "@SampsonBoatCo"
            {
              name = "@theslappablejerk";
              shorts = false;
            }
            "@treykennedy"
            "@whistlindiesel"
          ];
          Tech = [
            "@AdamJames-tv"
            "@KRAZAM"
            "@programmersarealsohuman5909" # Kai Lentit
          ];
          Outdoor = [
            "@bronandjacob"
            {
              name = "@ChrisburkardStudio";
              tier = "daily";
            }
            {
              name = "@courtneyevewhite";
              tier = "daily";
            }
            "@RabEquipment"
            "@theaudaciousreport"
          ];
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
        ocl-icd # OpenCL ICD loader
        # To make OBS HW recording work
        # https://discourse.nixos.org/t/trouble-getting-quicksync-to-work-with-jellyfin/42275
      ];
    };
  };

  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "iHD";
  };
  # Register the Intel OpenCL implementation with the ICD loader
  environment.etc."OpenCL/vendors/intel-neo.icd".source =
    "${pkgs.intel-compute-runtime}/etc/OpenCL/vendors/intel-neo.icd";

  environment.systemPackages = with pkgs; [
    intel-gpu-tools # intel_gpu_top for monitoring GPU usage during transcodes
  ];

  sops.secrets = {
    namecheap = { };
    apps_ondy_org_route53 = {
      # read by systemd as root (EnvironmentFile) before caddy drops privileges
      mode = "0400";
    };
    # AWS creds (svc.ddns) for the Route53 DDNS updater. EnvironmentFile format:
    # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY. Read by systemd as root.
    tiger_ddns_route53.mode = "0400";
    monitoring_password = {
      # vmagent/promtail use DynamicUser, need world-readable
      mode = "0444";
    };
    # Basic auth credentials for the monitoring write endpoints (read by Caddy).
    # Format: "username $2a$..." (bcrypt hash), one entry per line.
    monitoring_basicauth = {
      mode = "0440";
      group = "caddy";
    };
    # API keys consumed by the exportarr metrics exporters.
    sonarr_api_key.mode = "0444";
    radarr_api_key.mode = "0444";
    lidarr_api_key.mode = "0444";
    prowlarr_api_key.mode = "0444";
    bazarr_api_key.mode = "0444";
    sabnzbd_api_key.mode = "0444";
    # Consumed by the jellyfin backup service + jellyfin exporter.
    jellyfin_api_key.mode = "0444";
  };

  system.stateVersion = "21.11"; # Did you read the comment?
}
