{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [ ./hardware-configuration.nix ];

  networking = {
    hostName = "cheetah";
  };

  time.timeZone = "America/New_York";
  i18n = {
    defaultLocale = "en_US.UTF-8";
    extraLocaleSettings = {
      LC_ALL = "en_US.UTF-8";
    };
  };

  boot.binfmt.emulatedSystems = [
    "aarch64-linux"
    "armv7l-linux"
  ];

  # Configure mdadm to send notifications to root for RAID events
  boot.swraid.mdadmConf = "MAILADDR root@localhost";

  # Ensure website directory exists with proper permissions
  systemd.tmpfiles.rules = [
    "d /var/www/kyleondy.com 0755 nginx nginx -"
  ];

  systemFoundry = {
    nginxReverseProxy = {
      acme = {
        email = "kyle@ondy.org";
        dnsProvider = "route53";
        credentialsSecret = "apps_ondy_org_route53";
      };

      sites = {
        # Main website
        "www.kyleondy.com" = {
          enable = true;
          provisionCert = true;
          staticRoot = "/var/www/kyleondy.com";
          route53HostedZoneId = "Z0855021CRZ8TKMBC7EC";
        };

        # Default catch-all server that redirects to www.kyleondy.com
        "_" = {
          enable = true;
          isDefault = true;
          extraDomainNames = [ "www.kyleondy.com" ];
        };
      };
    };

    harmonia = {
      enable = true;
      domainName = "nix-cache.apps.ondy.org";
      provisionCert = true;
    };

    # VictoriaMetrics-based monitoring stack
    monitoringStack = {
      enable = true;
      domain = "apps.ondy.org";

      # Retention configuration
      retention = {
        metrics = 400; # days
        logs = 400; # days
      };

      # Bearer token authentication - hashes computed at runtime from sops secrets
      # The systemd service monitoring-token-hash-generator generates nginx map files
      # at /run/monitoring-token-hashes/*.conf which are included by nginx at runtime
      # No tokenHashes needed here - nginx includes the maps directly

      # Server-side components (central monitoring server)
      victoriametrics = {
        enable = true;
        provisionCert = true;
        domain = "metrics.apps.ondy.org";
      };

      loki = {
        enable = true;
        provisionCert = true;
        domain = "loki.apps.ondy.org";
      };

      grafana = {
        enable = true;
        provisionCert = true;
        domain = "grafana.apps.ondy.org";
      };

      alertmanager = {
        enable = true;
      };

      vmalert = {
        enable = true;
        provisionCert = true;
        domain = "vmalert.apps.ondy.org";
      };

      # Local monitoring agents (cheetah monitors itself)
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
        # Send metrics to local VictoriaMetrics instance
        remoteWriteUrl = "http://127.0.0.1:8428/api/v1/write";
        # Scrape local exporters
        scrapeConfigs = [
          {
            job_name = "node";
            static_configs = [
              {
                targets = [ "127.0.0.1:9100" ];
                labels = {
                  host = "cheetah";
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
                  host = "cheetah";
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
                  host = "cheetah";
                };
              }
            ];
          }
        ];
      };

      promtail = {
        enable = true;
        # Send logs to local Loki instance
        lokiUrl = "http://127.0.0.1:3100/loki/api/v1/push";
        extraLabels = {
          host = "cheetah";
        };
      };
    };
  };

  # SOPS secrets for monitoring
  sops.secrets = {
    monitoring_token_cheetah = {
      # vmagent service runs as DynamicUser, which means it can't be assigned
      # file ownership directly. Using mode 0444 allows the service to read it.
      # This is acceptable since the token is only used for authentication to
      # our own VictoriaMetrics instance, not external services.
      mode = "0444";
    };
    monitoring_token_tiger = {
      # Used by sops template for runtime hash computation and nginx auth
      mode = "0444";
    };
    monitoring_token_dino = {
      # Used by sops template for runtime hash computation and nginx auth
      mode = "0444";
    };
  };

  # Runtime computation of SHA-256 hashes from monitoring tokens
  # Hash computation is now handled by a systemd service that runs at boot
  # The service reads tokens from sops secrets and writes nginx map files to /run/monitoring-token-hashes
  systemd.services.monitoring-token-hash-generator = {
    description = "Generate SHA-256 hashes for monitoring bearer tokens";
    wantedBy = [ "multi-user.target" ];
    after = [ "sops-nix.service" ];
    before = [ "nginx.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      # Ensure runtime directory exists
      mkdir -p /run/monitoring-token-hashes

      # Read tokens from sops secrets and compute SHA-256 hashes
      cheetah_hash=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.monitoring_token_cheetah.path} | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)
      tiger_hash=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.monitoring_token_tiger.path} | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)
      dino_hash=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.monitoring_token_dino.path} | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)

      # Write metrics token map for nginx (VictoriaMetrics ingestion)
      cat > /run/monitoring-token-hashes/metrics-map.conf <<EOF
      # Validate token hash for VictoriaMetrics ingestion
      # Clients must send SHA-256 hash of their token as the bearer token
      map \$bearer_token \$valid_metrics_token {
        "$cheetah_hash" "1";
        "$tiger_hash" "1";
        "$dino_hash" "1";
        default "";
      }
      EOF

      # Write logs token map for nginx (Loki ingestion)
      cat > /run/monitoring-token-hashes/logs-map.conf <<EOF
      # Validate token hash for Loki ingestion
      # Clients must send SHA-256 hash of their token as the bearer token
      map \$bearer_token \$valid_logs_token {
        "$cheetah_hash" "1";
        "$tiger_hash" "1";
        "$dino_hash" "1";
        default "";
      }
      EOF

      # Set permissions so nginx can read them
      chmod 644 /run/monitoring-token-hashes/*.conf
    '';
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.05";
}
