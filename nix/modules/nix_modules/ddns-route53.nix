# Dynamic DNS updater for Route53.
#
# A bare apex (ondy.org, kyleondy.com) must be an A record and Route53 can't
# alias it into the tiger.infra -> home.1ella.com CNAME chain that tracks the
# home WAN IP. This timer-driven oneshot resolves the current WAN IP and UPSERTs
# it straight into the configured apex A records via the Route53 API.
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.ddnsRoute53;

  recordType = types.submodule {
    options = {
      zoneId = mkOption {
        type = types.str;
        description = "Route53 hosted zone ID containing the record.";
        example = "Z0365859SHHFAPNR0QXN";
      };
      name = mkOption {
        type = types.str;
        description = "Fully qualified record name to keep pointed at the WAN IP.";
        example = "ondy.org";
      };
    };
  };

  stateDir = "/var/lib/ddns-route53";
  stateFile = "${stateDir}/current_ip";
  textfile = "${config.systemFoundry.monitoringStack.nodeExporter.textfileDirectory}/ddns_route53.prom";

  updateScript = pkgs.writeShellApplication {
    name = "ddns-route53-update";
    runtimeInputs = [
      pkgs.curl
      pkgs.awscli2
      pkgs.coreutils
      pkgs.gawk
    ];
    text = ''
      readonly OUTFILE=${escapeShellArg textfile}

      # Resolve the current WAN IP from external echo services, with fallbacks.
      ip=""
      for url in https://checkip.amazonaws.com https://api.ipify.org https://ifconfig.co; do
        ip="$(curl -fsS --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
        if printf '%s' "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
          break
        fi
        ip=""
      done

      if [ -z "$ip" ]; then
        echo "ddns-route53: could not determine WAN IP from any provider" >&2
        exit 1
      fi

      last=""
      if [ -r "${stateFile}" ]; then
        last="$(cat "${stateFile}")"
      fi

      prior_metric() {
        awk -v pat="$1 " 'index($0, pat) == 1 { print $2 }' "$OUTFILE" 2>/dev/null || true
      }
      updates=$(prior_metric ddns_route53_record_updates_total)
      updates=''${updates:-0}
      last_success=$(prior_metric ddns_route53_last_success_timestamp_seconds)
      last_success=''${last_success:-0}
      failed=0

      if [ "$ip" = "$last" ]; then
        echo "ddns-route53: WAN IP unchanged ($ip), nothing to do"
      else
        echo "ddns-route53: WAN IP changed ''${last:-<none>} -> $ip, updating Route53"

        ${concatMapStringsSep "\n" (r: ''
          if aws route53 change-resource-record-sets \
            --hosted-zone-id ${r.zoneId} \
            --change-batch "{
              \"Changes\": [{
                \"Action\": \"UPSERT\",
                \"ResourceRecordSet\": {
                  \"Name\": \"${r.name}\",
                  \"Type\": \"A\",
                  \"TTL\": 300,
                  \"ResourceRecords\": [{\"Value\": \"$ip\"}]
                }
              }]
            }"; then
            updates=$(( updates + 1 ))
            echo "ddns-route53: upserted ${r.name} -> $ip"
          else
            failed=1
            echo "ddns-route53: failed to upsert ${r.name} -> $ip" >&2
          fi
        '') cfg.records}

        if [ "$failed" = 0 ]; then
          printf '%s' "$ip" > "${stateFile}"
        fi
      fi

      # The match is current_ip against the WAN IP, not a read of the records:
      # svc.ddns may only ChangeResourceRecordSets (tf/iam.tf), so a record
      # edited outside this updater still reads as a match.
      if [ "$failed" = 0 ]; then
        last_success=$(date +%s)
      fi
      tmp=$(mktemp "$OUTFILE.XXXXXX")
      {
        printf '# HELP ddns_route53_records_match_wan_ip 1 if every managed record was last set to the WAN IP this run detected\n'
        printf '# TYPE ddns_route53_records_match_wan_ip gauge\n'
        printf 'ddns_route53_records_match_wan_ip %s\n' "$(( 1 - failed ))"
        printf '# HELP ddns_route53_record_updates_total Record UPSERTs Route53 accepted\n'
        printf '# TYPE ddns_route53_record_updates_total counter\n'
        printf 'ddns_route53_record_updates_total %s\n' "$updates"
        printf '# HELP ddns_route53_last_success_timestamp_seconds Unix time a run last left every record on the WAN IP, 0 if none has\n'
        printf '# TYPE ddns_route53_last_success_timestamp_seconds gauge\n'
        printf 'ddns_route53_last_success_timestamp_seconds %s\n' "$last_success"
      } > "$tmp"
      chmod 0644 "$tmp"
      mv -fT "$tmp" "$OUTFILE"

      exit "$failed"
    '';
  };
in
{
  options.systemFoundry.ddnsRoute53 = {
    enable = mkEnableOption ''
      Route53 dynamic DNS updater: keeps apex A records pointed at the home WAN IP
    '';

    credentialsSecretPath = mkOption {
      type = types.path;
      description = ''
        Path to an EnvironmentFile holding AWS_ACCESS_KEY_ID and
        AWS_SECRET_ACCESS_KEY for an IAM principal allowed to change the
        configured records (e.g. a sops secret path).
      '';
      example = "/run/secrets/tiger_ddns_route53";
    };

    records = mkOption {
      type = types.listOf recordType;
      description = "Records to keep pointed at the current WAN IP.";
    };

    interval = mkOption {
      type = types.str;
      default = "5min";
      description = "How often to check the WAN IP (systemd OnUnitActiveSec value).";
    };
  };

  config = mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0700 root root -"
    ];

    systemd.services.ddns-route53 = {
      description = "Update Route53 apex A records with the home WAN IP";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        EnvironmentFile = cfg.credentialsSecretPath;
        ExecStart = getExe updateScript;
      };
    };

    systemd.timers.ddns-route53 = {
      description = "Periodic Route53 DDNS update timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = cfg.interval;
        AccuracySec = "10s";
      };
    };
  };
}
