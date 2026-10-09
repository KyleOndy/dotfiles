# pi as a read-only advisor: it triages each alert as it starts firing, and
# reviews the day's logs and metrics once a day for what static rules miss.
# It writes Markdown reports to /var/lib/pi-advisor/reports and acts on
# nothing.
#
# Mail is a separate unit that pi cannot reach: a path unit starts
# pi-advisor-mail whenever the reports directory changes, and it sends each
# new report to the monitoring stack's fixed recipients. The SMTP password is
# that unit's credential alone, and the model's only influence on a message
# is the report body it already writes.
#
# The boundary is the tool list. pi runs with no built-in tools (no bash,
# read, write or edit) and only the tools in pi-advisor/tools.ts: queries
# that each call one fixed GET path, a Kagi web search, and a Kagi page read
# limited to URLs that search returned. The unit confines pi itself: its own user, no capabilities,
# the state and cache directories as the only writable paths, the model and
# search keys as the only credentials, and no route to the LAN.
#
# Every query result goes to the model provider, including journal lines from
# every host and Caddy's access log. Search queries go to Kagi.
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = parentCfg.piAdvisor;

  smtp = parentCfg.smtp;
  reports = "/var/lib/pi-advisor/reports";
  # Kyle's, edited in place on tiger. Format: pi-advisor/README.md.
  acksDir = "/var/lib/pi-advisor-acks";
  acks = "${acksDir}/acknowledged.md";

  url = c: "http://${c.listenAddress}:${toString c.port}";

  hardening = {
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    PrivateIPC = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
    ];
    # AF_UNIX for nscd, which does the DNS lookups.
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    # Loopback and the internet (the model provider, the SMTP server), and
    # nothing private between them: not the LAN, the DMZ, WireGuard peers or
    # the UniFi console. An allow entry wins over a deny
    # (systemd.resource-control(5), IPAddressAllow=).
    IPAddressAllow = "localhost";
    IPAddressDeny = [
      "10.0.0.0/8"
      "172.16.0.0/12"
      "192.168.0.0/16"
      "100.64.0.0/10"
      "169.254.0.0/16"
      "224.0.0.0/4"
      "fc00::/7"
      "fe80::/10"
      "ff00::/8"
    ];
  };

  mailer = pkgs.writeShellApplication {
    name = "pi-advisor-mail";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.gnugrep
    ];
    text = ''
      # Report file names already sent, one per line.
      readonly MAILED="$STATE_DIRECTORY/mailed"
      readonly FOOTER="Already know about something in here? Add it to ${acks} on tiger and the daily sweeps will stop reporting it. Each entry covers one specific event, so a recurrence is still reported. Format: nix/modules/nix_modules/monitoring-stack/pi-advisor/README.md in the dotfiles repo."
      touch "$MAILED"
      shopt -s nullglob

      for report in ${reports}/*.md; do
        name=''${report##*/}
        grep -qxF "$name" "$MAILED" && continue

        # The first line is the header pi-advisor.sh writes from the alert's
        # labels or the sweep's name, never text from the model.
        subject=$(head -n 1 "$report" | tr -d '\r')
        {
          printf 'From: %s\nTo: %s\nSubject: [pi-advisor] %s\nDate: %s\n' \
            "${smtp.from}" "${concatStringsSep ", " smtp.to}" "''${subject#\# }" "$(date -R)"
          # base64 because a report is UTF-8 and its paragraphs run past
          # SMTP's 998-octet line limit (RFC 5322, section 2.1.1).
          printf 'MIME-Version: 1.0\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n\n'
          {
            cat "$report"
            printf '\n\n---\n\n%s\n' "$FOOTER"
          } | base64 -w 76
        } | curl -sS -m 60 --ssl-reqd --crlf -T - "smtp://${smtp.server}" \
          --variable "pw@$CREDENTIALS_DIRECTORY/smtp-password" \
          --expand-user "${smtp.username}:{{pw:trim}}" \
          --mail-from "${smtp.from}" \
          ${concatMapStringsSep " " (to: "--mail-rcpt ${escapeShellArg to}") smtp.to}

        echo "$name" >>"$MAILED"
        echo "mailed $name"
      done
    '';
  };

  advisor = pkgs.writeShellApplication {
    name = "pi-advisor";
    runtimeInputs = [
      pkgs.llm-agents.pi
      pkgs.coreutils
      pkgs.curl
      pkgs.findutils
      pkgs.gnugrep
      pkgs.jq
    ];
    text = builtins.readFile ./pi-advisor/pi-advisor.sh;
    # Backticks in its printf formats are Markdown fences, not expansions.
    excludeShellChecks = [ "SC2016" ];
  };

  mkService = mode: description: {
    inherit description;
    after = [
      "network-online.target"
      "victoriametrics.service"
      "loki.service"
      "alertmanager.service"
    ];
    wants = [ "network-online.target" ];

    environment = {
      PI_ADVISOR_ASSETS = "${./pi-advisor}";
      PI_ADVISOR_VM_URL = url parentCfg.victoriametrics;
      PI_ADVISOR_LOKI_URL = url parentCfg.loki;
      PI_ADVISOR_AM_URL = url parentCfg.alertmanager;
      PI_ADVISOR_VMALERT_URL = url parentCfg.vmalert;
      PI_ADVISOR_ACKS = acks;
      HOME = "/var/cache/pi-advisor";
      PI_CODING_AGENT_DIR = "/var/cache/pi-advisor";
    };

    serviceConfig = hardening // {
      Type = "oneshot";
      ExecStart = "${getExe advisor} ${mode}";
      # Three alert triages, or the two sweeps, at RUN_TIMEOUT each.
      TimeoutStartSec = "1h";
      User = "pi-advisor";
      Group = "pi-advisor";
      LoadCredential = [
        "zai:${cfg.apiKeyFile}"
        "kagi:${cfg.kagiApiKeyFile}"
      ];
      StateDirectory = "pi-advisor";
      StateDirectoryMode = "0750";
      CacheDirectory = "pi-advisor";
      CacheDirectoryMode = "0700";
      UMask = "0027";
      # No MemoryDenyWriteExecute: pi is a Bun binary, and JavaScriptCore's
      # JIT maps memory writable and executable.
    };
  };
in
{
  options.systemFoundry.monitoringStack.piAdvisor = {
    enable = mkEnableOption "pi, read-only, triaging alerts and sweeping logs and metrics";

    apiKeyFile = mkOption {
      type = types.path;
      description = "File holding the Z.ai Coding Plan API key.";
    };

    kagiApiKeyFile = mkOption {
      type = types.path;
      description = "File holding the Kagi API key web_search uses.";
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    users.users.pi-advisor = {
      isSystemUser = true;
      group = "pi-advisor";
    };
    users.groups.pi-advisor = { };

    # Owned by kyle so any editor can save there. setgid, so a file an editor
    # replaces on save still lands in group pi-advisor and stays readable.
    # The `f` argument is only a seed: tmpfiles writes it when the file does
    # not exist and never touches it again.
    systemd.tmpfiles.rules = [
      "d ${acksDir} 2750 kyle pi-advisor -"
      "f ${acks} 0640 kyle pi-advisor - ${
        concatStringsSep "\\n" [
          "# Acknowledged issues"
          ""
          "Format and rules: nix/modules/nix_modules/monitoring-stack/pi-advisor/README.md in the dotfiles repo."
          ""
          "- 2026-10-09: VictoriaMetrics crash-looped on a corrupt part in data/small/2026_10 (FATAL cannot merge, zstd window size exceeded) from 2026-10-04 to 2026-10-08, so metrics for those days are missing and vmalert could not evaluate rules. The data is gone. Report a new merge FATAL after 2026-10-08, not this one."
          ""
        ]
      }"
    ];

    systemd.services.pi-advisor-alerts = mkService "alerts" "Triage newly firing alerts with pi";
    systemd.services.pi-advisor-sweep = mkService "sweep" "Review the day's logs and metrics with pi";

    # A failed send leaves the report unmarked and the unit failed, which
    # SystemdServiceFailed reports; the next report to land retries it.
    systemd.services.pi-advisor-mail = {
      description = "Mail each new pi-advisor report";
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = getExe mailer;
        DynamicUser = true;
        # Read access to the reports, which are 0640 pi-advisor:pi-advisor.
        SupplementaryGroups = [ "pi-advisor" ];
        StateDirectory = "pi-advisor-mail";
        LoadCredential = [ "smtp-password:${config.sops.secrets.monitoring_smtp_password.path}" ];
        MemoryDenyWriteExecute = true;
      };
    };

    systemd.paths.pi-advisor-mail = {
      wantedBy = [ "paths.target" ];
      pathConfig.PathChanged = reports;
    };

    systemd.timers.pi-advisor-alerts = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitInactiveSec = "2min";
      };
    };

    systemd.timers.pi-advisor-sweep = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "06:00";
        Persistent = true;
      };
    };
  };
}
