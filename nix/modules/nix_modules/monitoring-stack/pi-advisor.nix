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
# that each call one fixed GET path, and a Kagi web search that returns
# snippets and never opens a page. The unit confines pi itself, in case
# pi or one of its dependencies ever runs code of its own: its own user, no
# capabilities, the state directory and a private /tmp as the only writable
# paths, the model and search keys as the only credentials, no route to the
# LAN, and on loopback only the four monitoring ports.
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
  queryPorts = map (c: toString c.port) [
    parentCfg.victoriametrics
    parentCfg.loki
    parentCfg.alertmanager
    parentCfg.vmalert
  ];

  hardening = {
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    ProtectSystem = "strict";
    ProtectHome = true;
    # The ZFS datasets under /mnt are world-readable, and so are the sockets
    # of the local daemons (D-Bus, Avahi, dhcpcd, winbind, sshd, Postgres).
    # Neither unit needs any of them; DNS goes through /run/nscd.
    InaccessiblePaths = [
      "-/mnt"
      "-/srv"
      "-/run/dbus"
      "-/run/avahi-daemon"
      "-/run/dhcpcd"
      "-/run/samba"
      "-/run/ssh-unix-local"
      "-/run/postgresql"
    ];
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
      pkgs.pandoc
    ];
    text = ''
      # Report file names already sent, one per line.
      readonly MAILED="$STATE_DIRECTORY/mailed"
      readonly FOOTER="Web research behind this report is limited on purpose: the advisor gets at most 5 searches a run and sees only their snippets, never the pages, since opening a page would give it a way to send data out. Treat the links as leads; anything that rests on one may need a closer read before acting on it.

      Already know about something in here? Add it to ${acks} on tiger and the daily sweeps will stop reporting it. Each entry covers one specific event, so a recurrence is still reported. Format: nix/modules/nix_modules/monitoring-stack/pi-advisor/README.md in the dotfiles repo."
      # base64 has no "-", so no line of an encoded part can match it.
      readonly BOUNDARY="pi-advisor-alternative"
      touch "$MAILED"
      shopt -s nullglob
      failed=0

      # part <content-type>: stdin as one MIME part. base64 because a report
      # is UTF-8 and its paragraphs run past SMTP's 998-octet line limit
      # (RFC 5322, section 2.1.1).
      part() {
        printf -- '--%s\nContent-Type: %s; charset=utf-8\nContent-Transfer-Encoding: base64\n\n' "$BOUNDARY" "$1"
        base64 -w 76
      }

      for report in ${reports}/*.md; do
        # pi-advisor owns this directory, and this unit holds a credential
        # pi-advisor does not, so a symlink, FIFO or anything else that is not
        # a plain file is never read.
        [[ -f $report && ! -L $report ]] || continue
        name=''${report##*/}
        grep -qxF "$name" "$MAILED" && continue

        # The first line is the header pi-advisor.sh writes from the alert's
        # labels or the sweep's name, never text from the model. Labels can
        # hold anything, so the subject keeps printable ASCII only, and stays
        # well inside the line limit.
        subject=$(head -n 1 "$report" | LC_ALL=C tr -cd '[:print:]' | cut -c 1-200)
        subject=''${subject#\# }
        body=$(
          cat "$report"
          printf '\n\n---\n\n%s' "$FOOTER"
        )

        # --sandbox keeps pandoc from reading any file but the filter.
        if ! html=$(pandoc -f gfm -t html5 -s --sandbox -L ${./pi-advisor/mail.lua} \
          -M pagetitle="$subject" <<<"$body"); then
          echo "could not render $name" >&2
          failed=1
          continue
        fi

        if ! {
          printf 'From: %s\nTo: %s\nSubject: [pi-advisor] %s\nDate: %s\n' \
            "${smtp.from}" "${concatStringsSep ", " smtp.to}" "$subject" "$(date -R)"
          printf 'MIME-Version: 1.0\nContent-Type: multipart/alternative; boundary="%s"\n\n' "$BOUNDARY"
          # A client shows the last part it can display (RFC 2046, section
          # 5.1.4), so the Markdown stays for anything that cannot render HTML.
          part text/plain <<<"$body"
          part text/html <<<"$html"
          printf -- '--%s--\n' "$BOUNDARY"
        } | curl -sS -m 60 --ssl-reqd --crlf -T - "smtp://${smtp.server}" \
          --variable "pw@$CREDENTIALS_DIRECTORY/smtp-password" \
          --expand-user "${smtp.username}:{{pw:trim}}" \
          --mail-from "${smtp.from}" \
          ${concatMapStringsSep " " (to: "--mail-rcpt ${escapeShellArg to}") smtp.to}; then
          echo "could not mail $name" >&2
          failed=1
          continue
        fi

        echo "$name" >>"$MAILED"
        echo "mailed $name"
      done

      exit "$failed"
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
      # pi reads settings, models, extensions and prompts from its agent
      # directory. PrivateTmp makes this one empty at the start of every run,
      # so nothing a run leaves behind reaches the next.
      HOME = "/tmp/pi";
      PI_CODING_AGENT_DIR = "/tmp/pi";
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
      UMask = "0027";
      # A run peaks near 110M. Query results are read whole before they are
      # cut down, so a huge one would otherwise take memory from the host.
      MemoryMax = "2G";
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
    assertions = [
      {
        assertion = config.networking.firewall.enable;
        message = "piAdvisor confines its loopback traffic with networking.firewall rules, which do nothing while the firewall is off.";
      }
    ];

    # IPAddressAllow= takes addresses, not ports, and the rest of loopback
    # holds Caddy's admin API, Syncthing's GUI and every app's API. So the
    # pi-advisor uid may open loopback connections to the four monitoring
    # ports and nothing else. The mailer runs under a DynamicUser uid, which
    # this does not match.
    networking.firewall.extraCommands = ''
      ip46tables -N pi-advisor-lo 2>/dev/null || true
      ip46tables -F pi-advisor-lo
      ip46tables -A pi-advisor-lo -p tcp -m multiport --dports ${concatStringsSep "," queryPorts} -j RETURN
      ip46tables -A pi-advisor-lo -j REJECT
      ip46tables -D OUTPUT -o lo -m owner --uid-owner pi-advisor -j pi-advisor-lo 2>/dev/null || true
      ip46tables -I OUTPUT -o lo -m owner --uid-owner pi-advisor -j pi-advisor-lo
    '';
    networking.firewall.extraStopCommands = ''
      ip46tables -D OUTPUT -o lo -m owner --uid-owner pi-advisor -j pi-advisor-lo 2>/dev/null || true
    '';

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
    # SystemdServiceFailed reports; the hourly timer retries it.
    systemd.services.pi-advisor-mail = {
      description = "Mail each new pi-advisor report";
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = getExe mailer;
        TimeoutStartSec = "5min";
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

    # A path unit stops watching while the service it started runs, so a
    # report that lands during a send waits for this.
    systemd.timers.pi-advisor-mail = {
      wantedBy = [ "timers.target" ];
      timerConfig.OnCalendar = "hourly";
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
