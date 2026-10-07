# qBittorrent, wired to run entirely inside the PIA network namespace from
# pia-wireguard-netns.nix. Everything else follows the *arr module's shape:
# batteries-included wrapper, Caddy site, web-UI-configured beyond that.
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.qbittorrent;
  netnsCfg = config.systemFoundry.piaWireguardNetns;
  textfileDir = config.systemFoundry.monitoringStack.nodeExporter.textfileDirectory;
  configDir = "${config.services.qbittorrent.profileDir}/qBittorrent/config";
  apiKeyFile = "${configDir}/webui-api-key";

  # Runs as qbittorrent before every start. 5.2.2 reads the key from
  # WebUI\APIKey in plain text and ignores any value that is not qbt_ plus 28
  # characters:
  # https://github.com/qbittorrent/qBittorrent/blob/release-5.2.2/src/base/utils/apikey.cpp#L36-L50
  # https://github.com/qbittorrent/qBittorrent/blob/release-5.2.2/src/webui/webapplication.cpp#L563-L564
  injectApiKeyScript = pkgs.writeShellApplication {
    name = "qbittorrent-inject-api-key";
    runtimeInputs = [
      pkgs.crudini
      pkgs.openssl
    ];
    text = ''
      readonly KEY_FILE=${escapeShellArg apiKeyFile}

      if [ ! -s "$KEY_FILE" ]; then
        key=$(openssl rand -hex 14)
        (umask 077 && printf 'qbt_%s' "$key" > "$KEY_FILE")
      fi
      # Through stdin, so the key never lands in crudini's argv.
      printf 'WebUI\\APIKey=%s\n' "$(< "$KEY_FILE")" \
        | crudini --ini-options=nospace --merge ${escapeShellArg "${configDir}/qBittorrent.conf"} Preferences
    '';
  };

  # Pushes the currently-forwarded PIA port (written by pia-wg-connect.service)
  # into qBittorrent's own listen port over its WebUI API. Safe to run
  # repeatedly: setting the same port is a no-op.
  setPortScript = pkgs.writeShellApplication {
    name = "qbittorrent-set-port";
    runtimeInputs = [
      pkgs.curl
      pkgs.coreutils
      pkgs.gawk
      pkgs.jq
    ];
    text = ''
      readonly KEY_FILE=${escapeShellArg apiKeyFile}
      readonly OUTFILE=${escapeShellArg "${textfileDir}/qbittorrent_set_port.prom"}
      last_success=$(awk -v pat="qbittorrent_set_port_last_success_timestamp_seconds " 'index($0, pat) == 1 { print $2 }' "$OUTFILE" 2>/dev/null || true)
      last_success=''${last_success:-0}
      matches=0

      # On every exit, so a run that skips or dies reads as a mismatch rather
      # than leaving the last match standing. Every exit is 0:
      # switch-to-configuration fails on any failed unit, so a transient
      # failure here would make deploy-rs roll back an unrelated tiger deploy.
      # QbittorrentPortMismatch reports a run that keeps failing.
      write_metrics() {
        local tmp
        tmp=$(mktemp "$OUTFILE.XXXXXX")
        {
          printf '# HELP qbittorrent_listen_port_matches_forwarded 1 if qBittorrent read back the PIA forwarded port as its listen port\n'
          printf '# TYPE qbittorrent_listen_port_matches_forwarded gauge\n'
          printf 'qbittorrent_listen_port_matches_forwarded %s\n' "$matches"
          printf '# HELP qbittorrent_set_port_last_success_timestamp_seconds Unix time a run last confirmed the match, 0 if none has\n'
          printf '# TYPE qbittorrent_set_port_last_success_timestamp_seconds gauge\n'
          printf 'qbittorrent_set_port_last_success_timestamp_seconds %s\n' "$last_success"
        } > "$tmp"
        chmod 0644 "$tmp"
        mv -fT "$tmp" "$OUTFILE"
      }
      trap 'write_metrics; exit 0' EXIT

      port_file="${netnsCfg.forwardedPortFile}"
      if [ ! -f "$port_file" ]; then
        echo "qbittorrent-set-port: $port_file doesn't exist yet, skipping" >&2
        exit 0
      fi
      port=$(cat "$port_file")

      base="http://${netnsCfg.vethNamespaceAddress}:8080"

      # The header goes in on stdin, so the key never lands in curl's argv.
      api() {
        printf 'Authorization: Bearer %s\n' "$(< "$KEY_FILE")" | curl -fsS -H @- "$@"
      }

      api --data-urlencode "json={\"listen_port\": $port}" \
        "$base/api/v2/app/setPreferences" >/dev/null

      actual=$(api "$base/api/v2/app/preferences" | jq -r '.listen_port')
      if [ "$actual" != "$port" ]; then
        echo "qbittorrent-set-port: listen_port reads $actual after setting $port" >&2
        exit 1
      fi
      matches=1
      last_success=$(date +%s)

      echo "qbittorrent-set-port: listen_port set to $port"
    '';
  };
in
{
  options.systemFoundry.qbittorrent = {
    enable = mkEnableOption "Batteries included wrapper for qBittorrent, routed through the PIA netns";

    group = mkOption {
      type = types.str;
      default = "qbittorrent";
      description = "Group to run qbittorrent under";
    };

    domainName = mkOption {
      type = types.str;
      description = "Domain to serve qbittorrent's WebUI under";
    };

    downloadsDir = mkOption {
      type = types.str;
      default = "/mnt/scratch-big/torrents";
      description = "The tree holding qBittorrent's incomplete and complete save paths";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = netnsCfg.enable;
        message = "systemFoundry.qbittorrent requires systemFoundry.piaWireguardNetns.enable, so its traffic doesn't fall through to the host's normal route.";
      }
    ];

    services.qbittorrent = {
      enable = true;
      group = cfg.group;
      webuiPort = 8080;
    };

    # qBittorrent.conf holds the API key in plain text and is rewritten under
    # the service's UMask=0002, so only the directory keeps other users out.
    systemd.tmpfiles.settings.qbittorrent."${configDir}/".d.mode = mkForce "0700";

    systemd.services.qbittorrent = {
      # Only netns-pia.service, not pia-wg-connect.service: the namespace
      # existing is all qbittorrent needs to start into. It gets no
      # connectivity until wg0 is plumbed in separately, which is fine --
      # avoids a startup cycle, since pushing the forwarded port back into
      # qbittorrent below needs qbittorrent already listening.
      after = [ "netns-pia.service" ];
      bindsTo = [ "netns-pia.service" ];

      serviceConfig = {
        # Per systemd.exec(5), NetworkNamespacePath= joins an existing
        # namespace regardless of PrivateNetwork= (which the upstream module
        # sets to false for its own reasons unrelated to this).
        NetworkNamespacePath = "/var/run/netns/${netnsCfg.namespace}";

        # `ip netns exec` bind-mounts /etc/netns/<name>/resolv.conf over
        # /etc/resolv.conf for anything it launches; NetworkNamespacePath=
        # doesn't get that for free, so qbittorrent does it directly.
        BindReadOnlyPaths = [
          "/etc/netns/${netnsCfg.namespace}/resolv.conf:/etc/resolv.conf"
        ];

        # Files land 664 so sonarr/radarr can import what qbittorrent
        # downloads. Group membership is the host's job: tiger sets
        # `group = mediaGroup`, which is already the process GID.
        UMask = "0002";

        # Unset, the WebUI listens on every address in the namespace,
        # wg0's included. qBittorrent has no command-line flag for the
        # address, and the WebUI owns the rest of qBittorrent.conf, so the
        # address and the API key are set in place. serverConfig would
        # replace the whole file on every start.
        ExecStartPre = [
          "${getExe pkgs.crudini} --ini-options=nospace --set ${configDir}/qBittorrent.conf Preferences WebUI\\\\Address ${netnsCfg.vethNamespaceAddress}"
          (getExe injectApiKeyScript)
        ];

        # Upstream leaves /tmp shared so a torrent can be added by path from
        # the command line; here torrents only arrive through the WebUI.
        PrivateTmp = mkForce true;
        ProtectSystem = mkForce "strict";
        ReadWritePaths = [
          config.services.qbittorrent.profileDir
          cfg.downloadsDir
        ];
        SystemCallFilter = [ "~@privileged" ];
      };
      unitConfig.RequiresMountsFor = [ cfg.downloadsDir ];
    };

    systemFoundry.caddyReverseProxy.sites."${cfg.domainName}" =
      mkIf config.systemFoundry.caddyReverseProxy.enable
        {
          enable = true;
          proxyPass = "http://${netnsCfg.vethNamespaceAddress}:8080";
        };

    systemd.services.qbittorrent-set-port = {
      description = "Push the PIA-forwarded port into qBittorrent's listen port";
      after = [ "qbittorrent.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = getExe setPortScript;
      };
    };

    systemd.timers.qbittorrent-set-port = {
      description = "Timer for pushing the PIA-forwarded port into qBittorrent";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "5min";
      };
    };
  };
}
