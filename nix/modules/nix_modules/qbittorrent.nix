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

  # Pushes the currently-forwarded PIA port (written by pia-wg-connect.service)
  # into qBittorrent's own listen port over its WebUI API -- the only
  # interface it has, qBittorrent has no separate machine-auth token like the
  # *arr apps' X-Api-Key. Safe to run repeatedly: setting the same port is a
  # no-op, and a qBittorrent-not-up-yet failure just waits for the next timer
  # tick rather than wedging any other unit.
  setPortScript = pkgs.writeShellApplication {
    name = "qbittorrent-set-port";
    runtimeInputs = [
      pkgs.curl
      pkgs.coreutils
    ];
    text = ''
      : "''${QBITTORRENT_USER:?QBITTORRENT_USER not set}"
      : "''${QBITTORRENT_PASS:?QBITTORRENT_PASS not set}"

      port_file="${netnsCfg.forwardedPortFile}"
      if [ ! -f "$port_file" ]; then
        echo "qbittorrent-set-port: $port_file doesn't exist yet, skipping" >&2
        exit 0
      fi
      port=$(cat "$port_file")

      base="http://${netnsCfg.vethNamespaceAddress}:8080"
      jar="''${RUNTIME_DIRECTORY:-/tmp}/cookies"

      curl -fsS -c "$jar" \
        --data-urlencode "username=$QBITTORRENT_USER" \
        --data-urlencode "password=$QBITTORRENT_PASS" \
        "$base/api/v2/auth/login" >/dev/null

      curl -fsS -b "$jar" \
        --data-urlencode "json={\"listen_port\": $port}" \
        "$base/api/v2/app/setPreferences" >/dev/null

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

    webuiCredentialsFile = mkOption {
      type = types.path;
      description = ''
        EnvironmentFile with QBITTORRENT_USER and QBITTORRENT_PASS (e.g. a
        sops secret path) -- qBittorrent's own WebUI login, bootstrapped
        through the UI on first boot and copied here so
        qbittorrent-set-port.service can authenticate to it.
      '';
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
      };
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
        RuntimeDirectory = "qbittorrent-set-port";
        EnvironmentFile = cfg.webuiCredentialsFile;
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
