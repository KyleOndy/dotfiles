{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.alertmanager;
in
{
  options.systemFoundry.monitoringStack.alertmanager = {
    enable = mkEnableOption "Alertmanager for alert routing and management";

    port = mkOption {
      type = types.port;
      default = 9093;
      description = "Port for Alertmanager web interface and API";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to listen on";
    };

    domain = mkOption {
      type = types.str;
      default = "alertmanager.${parentCfg.domain}";
      description = "Domain name for the Alertmanager UI (defaults to alertmanager.{parent domain})";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    sops.secrets.monitoring_smtp_password.mode = "0400";

    # DynamicUser, so the root-only file reaches it as a credential.
    systemd.services.alertmanager.serviceConfig.LoadCredential =
      "smtp-password:${config.sops.secrets.monitoring_smtp_password.path}";

    services.prometheus.alertmanager = {
      enable = true;
      listenAddress = cfg.listenAddress;
      port = cfg.port;

      # Disable clustering for single-node deployment
      extraFlags = [
        "--cluster.listen-address="
        "--cluster.advertise-address=127.0.0.1:9094"
        # Every "Silence" link in an alert email is built from this, so it has
        # to be Alertmanager's own hostname and it has to resolve off-network.
        "--web.external-url=https://${cfg.domain}"
      ];

      configuration = {
        route = {
          group_by = [ "alertname" ];
          group_wait = "10s";
          group_interval = "10s";
          repeat_interval = "1h";
          receiver = "default";
          routes = [
            {
              # Provider (Hetzner) has documented Percentage Used >= 100 as benign
              # while Available Spare > threshold. Keep the alert visible in the UI
              # but don't email on each repeat_interval.
              match = {
                alertname = "SmartDriveEnduranceExceeded";
              };
              receiver = "null";
            }
            {
              # Each one is a battery to order, a SATA cable to reseat or a file
              # to listen to, nothing an hour changes. The CRC and review rules'
              # 1d windows keep them firing for a day after a single event.
              matchers = [
                "alertname =~ \"UPSReplaceBattery|SmartLinkCrcErrorsIncreasing|MediaAudioNeedsReview\""
              ];
              repeat_interval = "24h";
            }
            {
              # Clearing an import block means opening the *arr UI and choosing
              # between a manual import and a blocklist, and arr-queue-janitor
              # sweeps whatever is left at 48h. Hourly mail buys no sooner fix.
              match = {
                alertgroup = "arr_queue_health";
              };
              repeat_interval = "24h";
            }
            {
              # A failed unit stays failed until someone opens a shell, and a
              # nightly oneshot cannot retry before its next timer. Hourly mail
              # restates the same units until then.
              match = {
                alertgroup = "systemd_health";
              };
              repeat_interval = "24h";
            }
            {
              # A push moves against a 2MB/s cap on a daily timer, so nothing
              # about the offsite copy changes inside an hour, and
              # S3ArchivePushStale fires only once no push is running at all.
              # Every repeat restates the same wait.
              match = {
                alertgroup = "offsite_archive";
              };
              repeat_interval = "24h";
            }
            {
              # Every alert in this group reads a nightly oneshot. The
              # housekeeping and stalled thresholds are days wide and the
              # bot-block window is 26h, so nothing here can change until the
              # next run. Hourly mail restates the same night.
              match = {
                alertgroup = "ytdl_sub";
              };
              repeat_interval = "24h";
            }
            {
              # The count comes from a daily sweep, so it cannot move between
              # runs, and replacing a file means finding a release and waiting
              # on a download. Hourly mail restates the same sweep.
              match = {
                alertgroup = "audio_language";
              };
              repeat_interval = "24h";
            }
          ];
        };

        # cogsworth and pika reach VictoriaMetrics only through Caddy on tiger,
        # so a Caddy outage drops their up series entirely and reads as a host
        # that stopped reporting. The write path is what broke, and the
        # InstanceDown carrying job=caddy already says so.
        inhibit_rules = [
          {
            source_matchers = [
              "alertname = InstanceDown"
              "job = caddy"
            ];
            target_matchers = [ "alertname = HostAbsent" ];
          }
          # tiger's upssched pushes UPSCommLost and UPSReplaceBattery without a
          # job label. The vmalert rules of the same names and the nut
          # scrape's InstanceDown carry job=nut and describe the same fault.
          # The UPSCommLost push resolves 2 minutes after COMMOK, so these
          # clear while still muted.
          {
            source_matchers = [
              "alertname =~ \"UPSCommLost|UPSReplaceBattery\""
              "job = \"\""
            ];
            target_matchers = [
              "alertname =~ \"UPSCommLost|UPSReplaceBattery\""
              "job = nut"
            ];
            equal = [
              "alertname"
              "host"
            ];
          }
          {
            source_matchers = [ "alertname = UPSCommLost" ];
            target_matchers = [
              "alertname = InstanceDown"
              "job = nut"
            ];
            equal = [ "host" ];
          }
        ];

        receivers = [
          (
            {
              name = "default";
            }
            // optionalAttrs (parentCfg.smtp.server != "") {
              email_configs = map (recipient: {
                to = recipient;
                send_resolved = true;
              }) parentCfg.smtp.to;
            }
          )
          { name = "null"; }
        ];
      }
      // optionalAttrs (parentCfg.smtp.server != "") {
        global = {
          smtp_smarthost = parentCfg.smtp.server;
          smtp_from = parentCfg.smtp.from;
          smtp_auth_username = parentCfg.smtp.username;
          smtp_auth_password_file = "/run/credentials/alertmanager.service/smtp-password";
        };
      };
    };

    # Basic auth on every path, same as vmalert: the UI is not read-only, it
    # creates and expires silences. The loopback callers (vmalert's notifier,
    # tiger's upssched dispatcher) hit 127.0.0.1:9093 directly and never pass
    # through Caddy, so they are unaffected.
    systemFoundry.caddyReverseProxy.sites."${cfg.domain}" =
      mkIf config.systemFoundry.caddyReverseProxy.enable
        {
          enable = true;
          proxyPass = "http://${cfg.listenAddress}:${toString cfg.port}";
          basicAuth = parentCfg.monitoringBasicAuth;
          basicAuthPaths = [ ]; # empty = protect all paths
        };
  };
}
