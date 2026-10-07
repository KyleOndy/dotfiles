{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.victoriametrics;
  smtp = parentCfg.smtp;
  am = parentCfg.alertmanager;
in
{
  options.systemFoundry.monitoringStack.victoriametrics = {
    enable = mkEnableOption "VictoriaMetrics metrics storage";

    port = mkOption {
      type = types.port;
      default = 8428;
      description = "Port for VictoriaMetrics HTTP API";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to listen on";
    };

    retentionPeriod = mkOption {
      type = types.int;
      default = parentCfg.retention.metrics;
      description = "Days to retain metrics (defaults to parent retention.metrics)";
    };

    domain = mkOption {
      type = types.str;
      default = "metrics.${parentCfg.domain}";
      description = "Domain name for VictoriaMetrics (defaults to metrics.{parent domain})";
    };

  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    services.victoriametrics = {
      enable = true;
      # The pure Go zstd decoder rejects valid storage blocks, so merges
      # panic on startup; drop once this is fixed upstream:
      # https://github.com/VictoriaMetrics/VictoriaMetrics/issues/11683
      package = pkgs.victoriametrics.overrideAttrs (old: {
        env = old.env // {
          CGO_ENABLED = 1;
        };
      });
      listenAddress = "${cfg.listenAddress}:${toString cfg.port}";
      retentionPeriod = "${toString cfg.retentionPeriod}d";
    };

    # Every vmalert rule queries VictoriaMetrics, so none can fire while it is
    # down. This mails directly as well as pushing to Alertmanager, which may
    # be down with it.
    systemd.services.victoriametrics-watchdog = {
      description = "Alert when VictoriaMetrics has not stayed up for 15 minutes";
      startAt = "minutely";
      path = [ pkgs.curl ];
      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        RuntimeDirectory = "victoriametrics-watchdog";
        # Survives between runs but not a reboot, so a stamp written while
        # tiger shut down cannot fire as soon as it boots.
        RuntimeDirectoryPreserve = true;
        LoadCredential = "smtp-password:${config.sops.secrets.monitoring_smtp_password.path}";
      };
      script = ''
        set -euo pipefail
        # Epoch seconds of the first check that found VictoriaMetrics unsettled.
        readonly SINCE="$RUNTIME_DIRECTORY/down-since"
        readonly MAILED="$RUNTIME_DIRECTORY/mailed"
        # A crash loop answers for about a second between panics.
        readonly SETTLED_SECONDS=300
        readonly ALERT_AFTER_SECONDS=900
        readonly HOST=${config.networking.hostName}

        stamp() {
          date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ
        }

        post() {
          curl -sS -m 10 -H 'Content-Type: application/json' \
            "http://${am.listenAddress}:${toString am.port}/api/v2/alerts" \
            -d '[{"labels":{"alertname":"VictoriaMetricsDown","severity":"critical","host":"'"$HOST"'"},"annotations":{"summary":"VictoriaMetrics on '"$HOST"' has not stayed up for 15 minutes","description":"No vmalert rule can fire while it is down. Check journalctl -u victoriametrics on '"$HOST"'."},"startsAt":"'"$1"'","endsAt":"'"$2"'"}]' || true
        }

        mail() {
          printf 'From: %s\nTo: %s\nSubject: %s\nDate: %s\n\n%s\n' \
            "${smtp.from}" "${concatStringsSep ", " smtp.to}" "$1" "$(date -R)" "$2" |
            curl -sS -m 60 --ssl-reqd --crlf -T - "smtp://${smtp.server}" \
              --variable "pw@$CREDENTIALS_DIRECTORY/smtp-password" \
              --expand-user "${smtp.username}:{{pw:trim}}" \
              --mail-from "${smtp.from}" \
              ${concatMapStringsSep " " (to: "--mail-rcpt ${escapeShellArg to}") smtp.to}
        }

        uptime=$(curl -fsS -m 10 http://${cfg.listenAddress}:${toString cfg.port}/metrics |
          sed -n 's/^vm_app_uptime_seconds //p') || true
        now=$(date +%s)

        if [[ -n $uptime ]] && ((uptime >= SETTLED_SECONDS)); then
          if [[ -e $MAILED ]]; then
            post "$(stamp "@$(<"$SINCE")")" "$(stamp now)"
            mail "VictoriaMetrics on $HOST is back up" "It has been answering for $uptime seconds."
          fi
          rm -f "$SINCE" "$MAILED"
          exit 0
        fi

        [[ -e $SINCE ]] || echo "$now" >"$SINCE"
        since=$(<"$SINCE")
        ((now - since >= ALERT_AFTER_SECONDS)) || exit 0

        post "$(stamp "@$since")" "$(stamp '+5 min')"
        if [[ ! -e $MAILED ]]; then
          mail "VictoriaMetrics on $HOST is down" "It has not stayed up since $(date -d "@$since"), so no vmalert rule can fire. Check journalctl -u victoriametrics on $HOST."
          touch "$MAILED"
        fi
      '';
    };

    # Basic auth on every path: the query, export and admin APIs
    # (delete_series, snapshot) are as dangerous as write. Grafana and
    # vmalert use loopback.
    systemFoundry.caddyReverseProxy.sites."${cfg.domain}" =
      mkIf config.systemFoundry.caddyReverseProxy.enable
        {
          enable = true;
          proxyPass = "http://${cfg.listenAddress}:${toString cfg.port}";
          basicAuth = parentCfg.monitoringBasicAuth;
        };
  };
}
