# Darwin-native equivalent of systemFoundry.monitoringStack (nix/modules/nix_modules/monitoring-stack/),
# which is NixOS-only (systemd.tmpfiles/services, DynamicUser) and cannot be
# imported under nix-darwin. Runs vmagent + node_exporter as launchd daemons
# instead of systemd services, reporting to the same tiger endpoint NixOS
# hosts use. Logs are not shipped: nothing on tiger reads them, and macOS
# keeps its own unified log for `log show`.
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

in
{
  options.systemFoundry.monitoringAgent = {
    enable = mkEnableOption "darwin-native vmagent/node_exporter reporting to tiger";

    hostLabel = mkOption {
      type = types.str;
      description = "Value for the host= label on all metrics sent to tiger";
    };

    remoteWriteUrl = mkOption {
      type = types.str;
      description = "VictoriaMetrics remote write URL";
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
      description = "Basic auth credentials for vmagent remote-write";
    };

  };

  config = mkIf cfg.enable {
    system.activationScripts.postActivation.text = ''
      mkdir -p ${logDir} /var/lib/vmagent
      # Writable by group admin because the writers are the login user's
      # launchd agents, and the login user is an admin on both Macs.
      mkdir -p ${cfg.textfileDirectory}
      chown root:admin ${cfg.textfileDirectory}
      chmod 0775 ${cfg.textfileDirectory}
    '';

    # `command`, not ProgramArguments, so nix-darwin waits for /nix/store via
    # /bin/wait4path. launchd loads these plists at boot before that volume
    # mounts, and a daemon exec'ing /nix/store directly stays in EX_CONFIG.
    launchd.daemons.node-exporter = {
      command = escapeShellArgs [
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
      serviceConfig = {
        Label = "org.ondy.node-exporter";
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${logDir}/node-exporter.log";
        StandardErrorPath = "${logDir}/node-exporter.log";
      };
    };

    launchd.daemons.vmagent = {
      command = escapeShellArgs (
        [
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
        ]
      );
      serviceConfig = {
        Label = "org.ondy.vmagent";
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${logDir}/vmagent.log";
        StandardErrorPath = "${logDir}/vmagent.log";
        EnvironmentVariables = {
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        };
      };
    };
  };
}
