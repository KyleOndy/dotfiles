# Isolates a torrent client's traffic behind a Private Internet Access
# WireGuard tunnel, so it can never fall back to the host's normal route.
#
# The isolation is a dedicated network namespace holding only a WireGuard
# interface to PIA plus a veth link back to the host (for Caddy/Sonarr/Radarr
# to reach the client's WebUI/RPC port). The namespace gets no default route
# other than the wg interface, so a dropped tunnel means no connectivity
# rather than a silent fall-through to the host's WAN -- the kill switch is
# an absence of routes, not an iptables rule to keep in sync.
#
# PIA's WireGuard connection isn't a static downloadable config: establishing
# one means authenticating for a token, generating an ephemeral keypair, and
# registering it against a chosen server's API. Port forwarding is a separate
# per-connection grant that expires if not refreshed. Both flows, including
# the exact endpoints and field names below, come from PIA's own reference
# implementation:
# https://github.com/pia-foss/manual-connections/tree/a1412dbe2ca41edbb79c766bc475335cb6cb13ad
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.piaWireguardNetns;

  # Pinned to the commit above so the cert can't silently change out from
  # under a deploy. It authenticates PIA's per-server API endpoints (addKey,
  # getSignature, bindPort), which are reached by IP via --connect-to rather
  # than DNS.
  piaCaCert = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/pia-foss/manual-connections/a1412dbe2ca41edbb79c766bc475335cb6cb13ad/ca.rsa.4096.crt";
    sha256 = "sha256-Mumx0UM+qXYU8qFMbjWOP1fAVwzJ9rLugSaZumlsZqs=";
  };

  runtimeDir = "pia-wg";
  runtimePath = "/run/${runtimeDir}";

  netnsSetup = pkgs.writeShellApplication {
    name = "netns-pia-setup";
    runtimeInputs = [
      pkgs.iproute2
      pkgs.procps
    ];
    text = ''
      ip netns list | grep -qx "${cfg.namespace}" || ip netns add "${cfg.namespace}"

      ip link add vethpia0 type veth peer name vethpia1
      ip link set vethpia1 netns "${cfg.namespace}"

      ip addr add ${cfg.vethHostAddress}/${toString cfg.vethPrefixLength} dev vethpia0
      ip link set vethpia0 up

      ip netns exec "${cfg.namespace}" ip addr add ${cfg.vethNamespaceAddress}/${toString cfg.vethPrefixLength} dev vethpia1
      ip netns exec "${cfg.namespace}" ip link set vethpia1 up
      ip netns exec "${cfg.namespace}" ip link set lo up

      # qbittorrent.service bind-mounts this file in at spawn time (see
      # qbittorrent.nix) and only depends on this unit, not pia-wg-connect,
      # to avoid a startup cycle -- so the source has to exist the moment
      # this unit is done, before pia-wg-connect has necessarily run.
      # pia-wg-connect overwrites it in place once connected; a bind mount
      # follows the same inode, so that update is visible immediately.
      mkdir -p "/etc/netns/${cfg.namespace}"
      touch "/etc/netns/${cfg.namespace}/resolv.conf"

      # PIA has no IPv6 support (https://github.com/pia-foss/manual-connections,
      # connect_to_wireguard_with_token.sh). Nothing routes it, but disable it
      # outright so a v6-capable client can't find a way around the kill switch.
      ip netns exec "${cfg.namespace}" sysctl -qw net.ipv6.conf.all.disable_ipv6=1
    '';
  };

  netnsTeardown = pkgs.writeShellApplication {
    name = "netns-pia-teardown";
    runtimeInputs = [ pkgs.iproute2 ];
    text = ''
      ip netns del "${cfg.namespace}" 2>/dev/null || true
    '';
  };

  wgConnect = pkgs.writeShellApplication {
    name = "pia-wg-connect";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.wireguard-tools
      pkgs.iproute2
      pkgs.coreutils
    ];
    text = ''
      : "''${PIA_USER:?PIA_USER not set}"
      : "''${PIA_PASS:?PIA_PASS not set}"

      mkdir -p "${runtimePath}" /etc/netns/${cfg.namespace}
      chmod 700 "${runtimePath}"

      region_data=$(curl -fsS https://serverlist.piaservers.net/vpninfo/servers/v6 | head -1)
      region=$(echo "$region_data" | jq -r --arg id "${cfg.region}" '.regions[] | select(.id == $id)')
      if [ -z "$region" ]; then
        echo "pia-wg-connect: region '${cfg.region}' not found in PIA's server list" >&2
        exit 1
      fi
      if [ "$(echo "$region" | jq -r '.port_forward')" != "true" ]; then
        echo "pia-wg-connect: region '${cfg.region}' does not support port forwarding" >&2
        exit 1
      fi

      wg_ip=$(echo "$region" | jq -r '.servers.wg[0].ip')
      wg_hostname=$(echo "$region" | jq -r '.servers.wg[0].cn')

      token=$(curl -fsS --location --request POST \
        'https://www.privateinternetaccess.com/api/client/v2/token' \
        --form "username=$PIA_USER" \
        --form "password=$PIA_PASS" | jq -r '.token')

      priv_key=$(wg genkey)
      pub_key=$(echo "$priv_key" | wg pubkey)

      wg_json=$(curl -fsS -G \
        --connect-to "$wg_hostname::$wg_ip:" \
        --cacert "${piaCaCert}" \
        --data-urlencode "pt=$token" \
        --data-urlencode "pubkey=$pub_key" \
        "https://$wg_hostname:1337/addKey")

      if [ "$(echo "$wg_json" | jq -r '.status')" != "OK" ]; then
        echo "pia-wg-connect: addKey did not return OK: $wg_json" >&2
        exit 1
      fi

      peer_ip=$(echo "$wg_json" | jq -r '.peer_ip')
      server_key=$(echo "$wg_json" | jq -r '.server_key')
      server_port=$(echo "$wg_json" | jq -r '.server_port')
      dns_server=$(echo "$wg_json" | jq -r '.dns_servers[0]')

      # Bring wg0 up inside the pia namespace directly, rather than writing a
      # wg-quick conf and running wg-quick -- wg-quick manages the DEFAULT
      # namespace's DNS/routes, and everything here needs to land in
      # "${cfg.namespace}" instead.
      ip link add wg0 type wireguard
      ip link set wg0 netns "${cfg.namespace}"

      ip netns exec "${cfg.namespace}" wg set wg0 \
        private-key <(echo "$priv_key") \
        peer "$server_key" \
        allowed-ips 0.0.0.0/0 \
        endpoint "$wg_ip:$server_port" \
        persistent-keepalive 25

      ip netns exec "${cfg.namespace}" ip addr add "$peer_ip" dev wg0
      ip netns exec "${cfg.namespace}" ip link set wg0 up
      ip netns exec "${cfg.namespace}" ip route replace default dev wg0

      # `ip netns exec` bind-mounts /etc/netns/<name>/resolv.conf over
      # /etc/resolv.conf for anything it launches (ip-netns(8)). qBittorrent
      # itself joins the namespace via systemd's NetworkNamespacePath instead,
      # which does not get that treatment, so its unit bind-mounts this same
      # file in directly (see qbittorrent.nix).
      echo "nameserver $dns_server" > "/etc/netns/${cfg.namespace}/resolv.conf"

      # Port forwarding: one getSignature call yields a payload+signature good
      # for the port's ~2 month life; only bindPort needs repeating (every
      # <15min, see the refresh timer), and only a fresh getSignature call
      # produces a new port to hand to qBittorrent.
      pf=$(curl -fsS -m 5 -G \
        --connect-to "$wg_hostname::$wg_ip:" \
        --cacert "${piaCaCert}" \
        --data-urlencode "token=$token" \
        "https://$wg_hostname:19999/getSignature")

      if [ "$(echo "$pf" | jq -r '.status')" != "OK" ]; then
        echo "pia-wg-connect: getSignature did not return OK: $pf" >&2
        exit 1
      fi

      echo "$pf" | jq -c --arg hostname "$wg_hostname" --arg gateway "$wg_ip" \
        '{payload: .payload, signature: .signature, hostname: $hostname, gateway: $gateway}' \
        > "${runtimePath}/port_forward.json"

      port=$(echo "$pf" | jq -r '.payload' | base64 -d | jq -r '.port')
      echo "$port" > "${runtimePath}/forwarded_port"
      echo "pia-wg-connect: connected via $wg_hostname ($wg_ip), forwarded port $port"
    '';
  };

  portForwardRefresh = pkgs.writeShellApplication {
    name = "pia-port-forward-refresh";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      state="${runtimePath}/port_forward.json"
      if [ ! -f "$state" ]; then
        echo "pia-port-forward-refresh: no $state yet, skipping until pia-wg-connect has run" >&2
        exit 0
      fi

      payload=$(jq -r '.payload' "$state")
      signature=$(jq -r '.signature' "$state")
      hostname=$(jq -r '.hostname' "$state")
      gateway=$(jq -r '.gateway' "$state")

      resp=$(curl -Gs -m 5 \
        --connect-to "$hostname::$gateway:" \
        --cacert "${piaCaCert}" \
        --data-urlencode "payload=$payload" \
        --data-urlencode "signature=$signature" \
        "https://$hostname:19999/bindPort")

      if [ "$(echo "$resp" | jq -r '.status')" != "OK" ]; then
        echo "pia-port-forward-refresh: bindPort did not return OK: $resp" >&2
        exit 1
      fi
    '';
  };

  healthcheck = pkgs.writeShellApplication {
    name = "pia-wg-healthcheck";
    runtimeInputs = [
      pkgs.wireguard-tools
      pkgs.iproute2
      pkgs.systemd
      pkgs.gawk
      pkgs.coreutils
    ];
    text = ''
      now=$(date +%s)
      # wg0 may not exist yet (pia-wg-connect hasn't run or is mid-retry);
      # pipefail would otherwise turn that into a hard failure of this
      # script instead of the "no handshake yet, restart" case below.
      handshake=$(ip netns exec "${cfg.namespace}" wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}') || true

      if [ -z "''${handshake:-}" ] || [ "$handshake" = "0" ] || [ $((now - handshake)) -gt 300 ]; then
        echo "pia-wg-healthcheck: no recent wg0 handshake, restarting pia-wg-connect.service"
        systemctl restart pia-wg-connect.service
      fi
    '';
  };
in
{
  options.systemFoundry.piaWireguardNetns = {
    enable = mkEnableOption "Network namespace with a PIA WireGuard tunnel and kill switch";

    namespace = mkOption {
      type = types.str;
      default = "pia";
      description = "Name of the network namespace to create.";
    };

    region = mkOption {
      type = types.str;
      default = "ca_toronto";
      description = ''
        PIA region id (from https://serverlist.piaservers.net/vpninfo/servers/v6)
        to connect to. Must be a region with port_forward = true -- PIA disables
        port forwarding on all US regions server-side.
      '';
    };

    credentialsFile = mkOption {
      type = types.path;
      description = "EnvironmentFile with PIA_USER and PIA_PASS (e.g. a sops secret path).";
    };

    vethHostAddress = mkOption {
      type = types.str;
      default = "10.250.250.1";
      description = "Host-side address of the veth link into the namespace.";
    };

    vethNamespaceAddress = mkOption {
      type = types.str;
      default = "10.250.250.2";
      description = "Namespace-side address of the veth link, e.g. for Caddy to proxy to.";
    };

    vethPrefixLength = mkOption {
      type = types.int;
      default = 30;
      description = "Prefix length for the veth link.";
    };

    forwardedPortFile = mkOption {
      type = types.path;
      default = "${runtimePath}/forwarded_port";
      description = ''
        Path holding the currently PIA-forwarded port as plain text, rewritten
        each time pia-wg-connect.service (re)connects. Consumers (e.g.
        qbittorrent.nix) read this to point their own listen port at it --
        this module has no opinion on what app is using the tunnel.
      '';
    };
  };

  config = mkIf cfg.enable {
    systemd.services.netns-pia = {
      description = "PIA network namespace and veth link";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = getExe netnsSetup;
        ExecStop = getExe netnsTeardown;
      };
    };

    systemd.services.pia-wg-connect = {
      description = "PIA WireGuard tunnel inside the pia namespace";
      # wantedBy, not just after/bindsTo: qbittorrent.service deliberately
      # does not pull this in (see qbittorrent.nix), so nothing else at boot
      # would start it otherwise.
      wantedBy = [ "multi-user.target" ];
      after = [ "netns-pia.service" ];
      bindsTo = [ "netns-pia.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = runtimeDir;
        EnvironmentFile = cfg.credentialsFile;
        ExecStart = getExe wgConnect;
      };
    };

    systemd.services.pia-port-forward-refresh = {
      description = "Refresh the PIA forwarded port before it expires";
      after = [ "pia-wg-connect.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = getExe portForwardRefresh;
      };
    };

    systemd.timers.pia-port-forward-refresh = {
      description = "Timer for PIA port-forward keepalive";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "10min";
        AccuracySec = "30s";
      };
    };

    systemd.services.pia-wg-healthcheck = {
      description = "Restart the PIA tunnel if it has gone stale";
      after = [ "pia-wg-connect.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = getExe healthcheck;
      };
    };

    systemd.timers.pia-wg-healthcheck = {
      description = "Timer for PIA tunnel health check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15min";
        OnUnitActiveSec = "1h";
      };
    };
  };
}
