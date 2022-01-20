# todo: replace all duplicated values (ports, dns names, etc) with vars
{ lib, pkgs, config, ... }:
with lib;
let
  cfg = config.systemFoundry.monitoring;
in
{
  options.systemFoundry.monitoring = {
    enable = mkEnableOption "home-infra monitoring stack";
  };

  config = mkIf cfg.enable {
    services = {
      prometheus = {
        enable = true;
        port = 9001;
        exporters = {
          node = {
            enable = true;
            enabledCollectors = [ "systemd" ];
            port = 9002;
          };
        };
        scrapeConfigs = [
          {
            job_name = "util";
            static_configs = [{
              targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
            }];
          }
        ];
      };
      grafana = {
        enable = true;
        domain = grafana_domain;
        port = 2342;
        addr = "127.0.0.1";
        security = {
          adminPasswordFile = /var/secrets/grafana_admin_pass;
        };
      };

      loki = {
        enable = true;
        configuration = {
          auth_enabled = false;
          server = {
            http_listen_port = 3100;
            grpc_listen_port = 9096;
          };
          common = {
            path_prefix = "/tmp/loki";
            "storage" = {
              "filesystem" = {
                "chunks_directory" = "/tmp/loki/chunks";
                "rules_directory" = "/tmp/loki/rules";
              };
            };
            "replication_factor" = 1;
            "ring" = {
              "instance_addr" = "127.0.0.1";
              "kvstore" = {
                "store" = "inmemory";
              };
            };
          };
          "schema_config" = {
            "configs" = [
              {
                "from" = "2020-10-24";
                "store" = "boltdb-shipper";
                "object_store" = "filesystem";
                "schema" = "v11";
                "index" = {
                  "prefix" = "index_";
                  "period" = "24h";
                };
              }
            ];
          };
          "ruler" = {
            "alertmanager_url" = "http://localhost:9093";
          };
        };
      };

      systemd.services.promtail = {
        description = "Promtail service for Loki";
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          ExecStart = ''
            ${pkgs.grafana-loki}/bin/promtail --config.file ${promtailConfig}
          '';
        };
      };

      # nginx reverse proxy
      services.nginx = {
        enable = true;
        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;
        virtualHosts.${grafana_domain} = {
          enableACME = false;
          forceSSL = true;
          sslCertificate = "/var/lib/acme/${grafana_domain}/cert.pem";
          sslCertificateKey = "/var/lib/acme/${grafana_domain}/key.pem";
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString config.services.grafana.port}";
            proxyWebsockets = true;
          };
        };
      };
    };

    # NEED this for certs to work. East to overlook!
    users.users.nginx.extraGroups = [ "acme" ];

    networking.firewall.allowedTCPPorts = [ 80 443 config.services.grafana.port ];
    networking.firewall.allowedUDPPorts = [ 80 443 config.services.grafana.port ];

    security.acme = {
      email = "kyle@ondy.org";
      acceptTerms = true;
      certs = {
        "${grafana_domain}" = {
          dnsProvider = "namecheap";
          credentialsFile = config.sops.secrets.namecheap.path;
          extraDomainNames = [ ];
        };
      };
    };

    sops.secrets = {
      grafana_admin_pass = {
        owner = "grafana";
        group = "grafana";
      };
      unifi = {
        owner = "unifi-poller";
        group = "unifi-poller";
      };
    };
  };
}
