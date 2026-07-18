# Darwin-native equivalent of systemFoundry.monitoringStack (nix/modules/nix_modules/monitoring-stack/),
# which is NixOS-only (systemd.tmpfiles/services, DynamicUser) and cannot be
# imported under nix-darwin. Runs vmagent + node_exporter + promtail as
# launchd daemons instead of systemd services, reporting to the same tiger
# endpoints dino uses.
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.monitoringAgent;
  logDir = "/var/log/monitoring-agent";

  vmagentScrapeConfig = pkgs.writeText "vmagent-scrape-config.yaml" (
    builtins.toJSON {
      global.scrape_interval = "15s";
      scrape_configs = cfg.scrapeConfigs;
    }
  );

  promtailConfig = pkgs.writeText "promtail-config.yaml" (
    builtins.toJSON {
      server = {
        http_listen_port = 9080;
        grpc_listen_port = 0;
      };
      positions.filename = "/var/lib/promtail/positions.yaml";
      clients = [
        (
          {
            url = cfg.lokiUrl;
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
          # macOS has no journald; this tails a continuously-running `log
          # stream` capture (see the log-capture daemon below) instead of
          # promtail scraping the log source directly.
          job_name = "darwin-unified-log";
          static_configs = [
            {
              targets = [ "localhost" ];
              labels = {
                job = "darwin-unified-log";
                host = cfg.hostLabel;
                __path__ = "${logDir}/unified.log";
              };
            }
          ];
        }
      ];
    }
  );
in
{
  options.systemFoundry.monitoringAgent = {
    enable = mkEnableOption "darwin-native vmagent/node_exporter/promtail reporting to tiger";

    hostLabel = mkOption {
      type = types.str;
      description = "Value for the host= label on all metrics/logs sent to tiger";
    };

    remoteWriteUrl = mkOption {
      type = types.str;
      description = "VictoriaMetrics remote write URL";
    };

    lokiUrl = mkOption {
      type = types.str;
      description = "Loki push URL";
    };

    basicAuth = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            username = mkOption { type = types.str; };
            passwordFile = mkOption { type = types.path; };
          };
        }
      );
      default = null;
      description = "Basic auth credentials shared by vmagent remote-write and promtail push";
    };

    scrapeConfigs = mkOption {
      type = types.listOf types.attrs;
      default = [
        {
          job_name = "node";
          static_configs = [
            {
              targets = [ "127.0.0.1:9100" ];
              labels = {
                host = cfg.hostLabel;
              };
            }
          ];
        }
      ];
      description = "Prometheus scrape configurations for vmagent";
    };
  };

  config = mkIf cfg.enable {
    system.activationScripts.postActivation.text = ''
      mkdir -p ${logDir} /var/lib/vmagent /var/lib/promtail
    '';

    launchd.daemons.node-exporter = {
      serviceConfig = {
        Label = "org.ondy.node-exporter";
        ProgramArguments = [
          "${pkgs.prometheus-node-exporter}/bin/node_exporter"
          "--web.listen-address=127.0.0.1:9100"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${logDir}/node-exporter.log";
        StandardErrorPath = "${logDir}/node-exporter.log";
      };
    };

    launchd.daemons.vmagent = {
      serviceConfig = {
        Label = "org.ondy.vmagent";
        ProgramArguments = [
          "${pkgs.vmagent}/bin/vmagent"
          "-remoteWrite.url=${cfg.remoteWriteUrl}"
          "-remoteWrite.tmpDataPath=/var/lib/vmagent/remote_write_tmp"
          "-promscrape.config=${vmagentScrapeConfig}"
        ]
        ++ optionals (cfg.basicAuth != null) [
          "-remoteWrite.basicAuth.username=${cfg.basicAuth.username}"
          "-remoteWrite.basicAuth.passwordFile=${toString cfg.basicAuth.passwordFile}"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${logDir}/vmagent.log";
        StandardErrorPath = "${logDir}/vmagent.log";
        EnvironmentVariables = {
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        };
      };
    };

    # Continuously captures the macOS unified log to a plain file so
    # promtail has something file-based to tail (there's no journald on
    # darwin). `--level default` drops debug/info noise to keep growth
    # bounded; nothing here rotates the file yet, so /var/log/monitoring-agent
    # disk usage is worth checking after trex has been running a while.
    launchd.daemons.log-capture = {
      serviceConfig = {
        Label = "org.ondy.log-capture";
        ProgramArguments = [
          "/usr/bin/log"
          "stream"
          "--style"
          "syslog"
          "--level"
          "default"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${logDir}/unified.log";
        StandardErrorPath = "${logDir}/log-capture.err.log";
      };
    };

    launchd.daemons.promtail = {
      serviceConfig = {
        Label = "org.ondy.promtail";
        ProgramArguments = [
          "${pkgs.promtail}/bin/promtail"
          "-config.file=${promtailConfig}"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${logDir}/promtail.log";
        StandardErrorPath = "${logDir}/promtail.log";
      };
    };
  };
}
