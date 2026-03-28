{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.promtail;
in
{
  options.systemFoundry.monitoringStack.promtail = {
    enable = mkEnableOption "promtail for log shipping to Loki";

    lokiUrl = mkOption {
      type = types.str;
      description = "Loki push URL";
      example = "https://loki.elk.infra.ondy.org/loki/api/v1/push";
    };

    bearerTokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to file containing bearer token for authentication (nginx hosts)";
    };

    basicAuth = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            username = mkOption {
              type = types.str;
              description = "Basic auth username";
            };
            passwordFile = mkOption {
              type = types.path;
              description = "Path to file containing the basic auth password";
            };
          };
        }
      );
      default = null;
      description = "Basic auth credentials for Loki push (Caddy hosts)";
    };

    extraLabels = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra labels to add to all log entries";
      example = {
        host = "wolf";
        environment = "production";
      };
    };

    extraScrapeConfigs = mkOption {
      type = types.listOf types.attrs;
      default = [ ];
      description = "Additional scrape configurations to add to promtail";
      example = [
        {
          job_name = "jellyfin";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "jellyfin";
                host = "elk";
                __path__ = "/var/lib/jellyfin/log/*.log";
              };
            }
          ];
        }
      ];
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    # Ensure promtail state directory exists
    systemd.tmpfiles.rules = [
      "d /var/lib/promtail 0755 promtail promtail -"
    ];

    # Grant promtail access to nginx and jellyfin logs
    users.users.promtail.extraGroups =
      (optional config.services.nginx.enable "nginx")
      ++ (optional config.services.jellyfin.enable "media");

    services.promtail = {
      enable = true;
      configuration = {
        server = {
          http_listen_port = 9080;
          grpc_listen_port = 0;
        };

        positions = {
          filename = "/var/lib/promtail/positions.yaml";
        };

        clients = [
          (
            {
              url = cfg.lokiUrl;
            }
            // optionalAttrs (cfg.bearerTokenFile != null) {
              bearer_token_file = toString cfg.bearerTokenFile;
            }
            // optionalAttrs (cfg.basicAuth != null) {
              basic_auth = {
                username = cfg.basicAuth.username;
                password_file = toString cfg.basicAuth.passwordFile;
              };
            }
          )
        ];

        scrape_configs = [
          {
            job_name = "systemd-journal";
            journal = {
              max_age = "12h";
              labels = {
                job = "systemd-journal";
              }
              // cfg.extraLabels;
            };
            relabel_configs = [
              {
                source_labels = [ "__journal__systemd_unit" ];
                target_label = "unit";
              }
              {
                source_labels = [ "__journal__hostname" ];
                target_label = "hostname";
              }
              {
                source_labels = [ "__journal_priority_keyword" ];
                target_label = "level";
              }
            ];
          }
        ]
        # Only scrape nginx access log if nginx is running
        ++ optional config.services.nginx.enable {
          job_name = "nginx";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "nginx";
                unit = "nginx.service";
                __path__ = "/var/log/nginx/access.log";
              }
              // cfg.extraLabels;
            }
          ];
        }
        ++ cfg.extraScrapeConfigs;
      };
    };
  };
}
