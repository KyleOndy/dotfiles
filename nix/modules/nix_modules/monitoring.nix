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
        listenAddress = "127.0.0.1";
        # todo: some kind of mapAttrs to cut down on copy/paste
        # todo: https tagets
        scrapeConfigs = [
          {
            job_name = "hosts";
            static_configs = [{
              targets = [
                "alpha.lan.1ella.com"
                "util.lan.1ella.com"
              ];
            }];
          }
        ];
      };
      grafana = {
        enable = true;
        domain = "grafana.apps.lan.1ella.com";
        port = 2342;
        addr = "127.0.0.1";
        security = {
          adminPasswordFile = config.sops.secrets.grafana_admin_pass.path;
        };
        provision = {
          enable = true;
          datasources = [
            {
              type = "prometheus";
              isDefault = true;
              name = "Prometheus";
              url = "http://127.0.0.1:9001";
            }
          ];
        };
      };
      nginx = {
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

    networking.firewall.allowedTCPPorts = [ 80 443 config.services.grafana.port ];
    security.acme = {
      certs = {
        "${config.services.grafana.domain}" = {
          dnsProvider = "namecheap";
          credentialsFile = config.sops.secrets.namecheap.path;
          extraDomainNames = [ ];
        };
      };
    };
    # todo: where is a better place to put this?
    # NEED this for certs to work. East to overlook!
    users.users.nginx.extraGroups = [ "acme" ];
    sops.secrets = {
      namecheap = {
        owner = "acme";
        group = "acme";
      };
      grafana_admin_pass = {
        owner = "grafana";
        group = "grafana";
      };
    };
  };
}
