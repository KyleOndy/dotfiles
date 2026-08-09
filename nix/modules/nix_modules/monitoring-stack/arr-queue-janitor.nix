{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.arrQueueJanitor;

  textfile = "/var/lib/prometheus-node-exporter-text-files/arr_queue_janitor.prom";

  mkAppOptions = servicePort: defaultApiVersion: {
    enable = mkEnableOption "queue janitor for this service";

    url = mkOption {
      type = types.str;
      default = "http://127.0.0.1:${toString servicePort}";
      description = "URL to the service";
    };

    apiVersion = mkOption {
      type = types.str;
      default = defaultApiVersion;
      description = ''
        Path segment of the queue API. Sonarr and Radarr are on v3, Lidarr is
        still on v1 and answers 404 to a v3 request.
      '';
    };

    apiKeyFile = mkOption {
      type = types.path;
      description = "Path to file containing API key for the service";
    };
  };

  enabledApps = filterAttrs (_: appCfg: appCfg.enable) {
    inherit (cfg) sonarr radarr lidarr;
  };
in
{
  options.systemFoundry.monitoringStack.arrQueueJanitor = {
    enable = mkEnableOption "periodic removal of stuck *arr queue items";

    graceHours = mkOption {
      type = types.ints.positive;
      default = 48;
      description = ''
        Hours an item may sit in a blocked state before it is removed and
        blocklisted. Measured from the queue record's `added` timestamp, so it
        counts from the grab and not from when the item became blocked. Keep it
        above the `for:` on the *ImportBlocked alerts, or the sweep beats the
        mail that asks for a decision.
      '';
    };

    sonarr = mkAppOptions 8989 "v3";
    radarr = mkAppOptions 7878 "v3";
    lidarr = mkAppOptions 8686 "v1";
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    systemd.services.arr-queue-janitor = {
      description = "Remove *arr queue items stuck past the manual-import window";
      after = [ "network.target" ];

      path = [
        pkgs.curl
        pkgs.jq
        pkgs.coreutils
        pkgs.gawk
      ];

      # root, like the other textfile producers: the .prom directory is
      # root-owned 0755 and the sops API keys are 0440.
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };

      script = ''
        set -euo pipefail

        readonly OUTFILE="${textfile}"
        readonly CUTOFF=$(( ${toString cfg.graceHours} * 3600 ))
        now=$(date +%s)

        {
          printf '# HELP arr_queue_janitor_removed_total Queue items removed and blocklisted\n'
          printf '# TYPE arr_queue_janitor_removed_total counter\n'
          printf '# HELP arr_queue_janitor_last_run_timestamp_seconds Unix time this app was last swept successfully\n'
          printf '# TYPE arr_queue_janitor_last_run_timestamp_seconds gauge\n'
        } > "$OUTFILE.tmp"

        # index()==1 is the anchor; a "^" here would be matched literally and
        # every lookup would miss, resetting the counter on each run.
        prior_metric() {
          awk -v pat="$1{app=\"$2\"} " '
            index($0, pat) == 1 { print $2 }
          ' "$OUTFILE" 2>/dev/null || true
        }

        sweep_app() {
          local app="$1" url="$2" keyfile="$3" api="$4"
          local key queue targets id title
          local removed=0 last_run

          local prior_removed
          prior_removed=$(prior_metric arr_queue_janitor_removed_total "$app")
          prior_removed=''${prior_removed:-0}
          last_run=$(prior_metric arr_queue_janitor_last_run_timestamp_seconds "$app")
          last_run=''${last_run:-0}

          if queue=$(curl -sf --max-time 30 -H "X-Api-Key: $(cat "$keyfile")" \
                       "$url/api/$api/queue?pageSize=200"); then
            # Fractional seconds appear on some records and fromdateiso8601
            # rejects them.
            targets=$(printf '%s' "$queue" | jq -r --argjson now "$now" --argjson cutoff "$CUTOFF" '
              .records[]
              | select(.added != null)
              # importFailed is where Lidarr parks an incomplete release;
              # Sonarr and Radarr call the same condition importBlocked.
              | select(.trackedDownloadState == "importBlocked"
                       or .trackedDownloadState == "importFailed"
                       or .trackedDownloadState == "failedPending")
              | select(((.added | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) + $cutoff) <= $now)
              | "\(.id)\t\(.title)"')

            key=$(cat "$keyfile")
            while IFS=$'\t' read -r id title; do
              [ -n "$id" ] || continue
              # skipRedownload=false is what makes the *arr search for a
              # replacement after blocklisting; without it the item is simply
              # dropped and the movie or episode stays missing.
              if curl -sf --max-time 30 -X DELETE -o /dev/null -H "X-Api-Key: $key" \
                   "$url/api/$api/queue/$id?removeFromClient=true&blocklist=true&skipRedownload=false"; then
                echo "removed $app queue item $id: $title"
                removed=$(( removed + 1 ))
              else
                echo "failed to remove $app queue item $id: $title" >&2
              fi
            done <<< "$targets"

            last_run="$now"
          else
            echo "could not read the $app queue at $url, leaving it alone" >&2
          fi

          printf 'arr_queue_janitor_removed_total{app="%s"} %s\n' \
            "$app" "$(( prior_removed + removed ))" >> "$OUTFILE.tmp"
          printf 'arr_queue_janitor_last_run_timestamp_seconds{app="%s"} %s\n' \
            "$app" "$last_run" >> "$OUTFILE.tmp"
        }

        ${concatStringsSep "\n" (
          mapAttrsToList (
            app: appCfg: ''sweep_app ${app} "${appCfg.url}" "${appCfg.apiKeyFile}" "${appCfg.apiVersion}"''
          ) enabledApps
        )}

        mv "$OUTFILE.tmp" "$OUTFILE"
      '';
    };

    systemd.timers.arr-queue-janitor = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15min";
        OnUnitActiveSec = "6h";
        Persistent = true;
      };
    };
  };
}
