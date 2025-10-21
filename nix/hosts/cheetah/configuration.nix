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
      # The template file is created at activation time, so we provide a dummy value during evaluation
      tokenHashes =
        if builtins.pathExists config.sops.templates."monitoring-token-hashes.nix".path then
          import config.sops.templates."monitoring-token-hashes.nix".path
        else
          {
            # Dummy hashes for evaluation - real hashes computed at activation
            cheetah = "";
            tiger = "";
            dino = "";
          };

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
      };

      # Local monitoring agents (cheetah monitors itself)
      nodeExporter = {
        enable = true;
      };

      vmagent = {
        enable = true;
        # Send metrics to local VictoriaMetrics instance
        remoteWriteUrl = "http://127.0.0.1:8428/api/v1/write";
        # Scrape local node_exporter
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
    monitoring_token_cheetah = { };
    monitoring_token_tiger = { };
    monitoring_token_dino = { };
  };

  # Runtime computation of SHA-256 hashes from monitoring tokens
  # This template generates a Nix attrset file that can be imported
  sops.templates."monitoring-token-hashes.nix" = {
    content = ''
      {
        cheetah = "$(echo -n '${config.sops.placeholder.monitoring_token_cheetah}' | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)";
        tiger = "$(echo -n '${config.sops.placeholder.monitoring_token_tiger}' | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)";
        dino = "$(echo -n '${config.sops.placeholder.monitoring_token_dino}' | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d' ' -f1)";
      }
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
