# Darwin-native equivalent of systemFoundry.monitoringStack (nix/modules/nix_modules/monitoring-stack/),
# which is NixOS-only (systemd.tmpfiles/services, DynamicUser) and cannot be
# imported under nix-darwin. Runs vmagent + node_exporter + alloy as
# launchd daemons instead of systemd services, reporting to the same tiger
# endpoints NixOS hosts use.
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
      # The Macs run one exporter and always will; there is nothing to
      # configure until a second one shows up.
      scrape_configs = [
        {
          job_name = "node";
          static_configs = [
            {
              targets = [ "127.0.0.1:9100" ];
              labels.host = cfg.hostLabel;
            }
          ];
        }
      ];
    }
  );

  # Interpolating a multi-line string into an indented one does not re-indent
  # it, so this block lands flush left in the generated file.
  basicAuthBlock = optionalString (cfg.basicAuth != null) ''

    basic_auth {
      username      = "${cfg.basicAuth.username}"
      password_file = "${toString cfg.basicAuth.passwordFile}"
    }'';

  alloyConfig = pkgs.writeText "config.alloy" ''
    loki.write "default" {
      endpoint {
        url = "${cfg.lokiUrl}"${basicAuthBlock}
      }
      external_labels = { host = "${cfg.hostLabel}" }
    }

    // macOS has no journald; this tails a continuously-running `log stream`
    // capture (see the log-capture daemon below) rather than reading the log
    // source directly.
    loki.source.file "darwin_unified_log" {
      targets = [{
        __path__ = "${logDir}/unified.log",
        job      = "darwin-unified-log",
      }]
      forward_to = [loki.write.default.receiver]

      // The capture file is whatever `log stream` has written since the daemon
      // last started, so a first start with no stored position would replay it
      // from the top.
      tail_from_end = true
    }
  '';
in
{
  options.systemFoundry.monitoringAgent = {
    enable = mkEnableOption "darwin-native vmagent/node_exporter/alloy reporting to tiger";

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

    textfileDirectory = mkOption {
      type = types.str;
      default = "/var/lib/node-exporter-textfile";
      readOnly = true;
      description = "Directory node_exporter's textfile collector reads *.prom files from";
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
      description = "Basic auth credentials shared by vmagent remote-write and the Loki push";
    };

  };

  config = mkIf cfg.enable {
    system.activationScripts.postActivation.text = ''
      mkdir -p ${logDir} /var/lib/vmagent /var/lib/alloy
      # Writable by group admin because the writers are the login user's
      # launchd agents, and the login user is an admin on both Macs.
      mkdir -p ${cfg.textfileDirectory}
      chown root:admin ${cfg.textfileDirectory}
      chmod 0775 ${cfg.textfileDirectory}
    '';

    launchd.daemons.node-exporter = {
      serviceConfig = {
        Label = "org.ondy.node-exporter";
        ProgramArguments = [
          "${pkgs.prometheus-node-exporter}/bin/node_exporter"
          "--web.listen-address=127.0.0.1:9100"
          # Every APFS volume in a container reports the container's free
          # space, so one full disk raises one alert per volume. Data is the
          # only one whose number is actionable. The smbfs mounts are tiger's
          # shares, already monitored on tiger.
          "--collector.filesystem.mount-points-exclude=^/(dev|nix|System/Volumes/(Preboot|Update|VM|xarts|iSCPreboot|Hardware))($|/)"
          "--collector.filesystem.fs-types-exclude=^(devfs|autofs|smbfs)$"
          "--collector.textfile.directory=${cfg.textfileDirectory}"
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
          # The default is every interface, where /api/v1/write would relay
          # anything sent to it under this host's tiger credential.
          "-httpListenAddr=127.0.0.1:8429"
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

    # Continuously captures the macOS unified log to a plain file so alloy
    # has something file-based to tail (there's no journald on
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

    launchd.daemons.alloy = {
      serviceConfig = {
        Label = "org.ondy.alloy";
        ProgramArguments = [
          "${pkgs.grafana-alloy}/bin/alloy"
          "run"
          # Alloy phones home a component inventory to Grafana on startup
          # unless told not to.
          # https://grafana.com/docs/alloy/latest/data-collection/
          "--disable-reporting"
          "--storage.path=/var/lib/alloy"
          "${alloyConfig}"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${logDir}/alloy.log";
        StandardErrorPath = "${logDir}/alloy.log";
        EnvironmentVariables = {
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        };
      };
    };
  };
}
