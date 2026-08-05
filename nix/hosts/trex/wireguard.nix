# WireGuard client for the VPN server on the UDM Pro.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  # The UDM Pro's WireGuard server, from Settings > VPN > VPN Server.
  serverPublicKey = "r4+6mEOGrmldIt+aSAYGzEDLMppbugpkyq2oBfxDo1M=";
  # home.1ella.com tracks the WAN IP through the UniFi console's own DDNS
  # updater, independent of tiger's systemFoundry.ddnsRoute53 (tf/dns.tf:93).
  endpoint = "home.1ella.com:51820";

  # 192.168.5.2 and .3 belonged to dino and elk, both decommissioned.
  address = [ "192.168.5.4/32" ];

  # The UDM's LAN address, not the 192.168.5.1 tunnel gateway that UniFi
  # writes into the config it hands out. Nothing answers on port 53 there:
  #   $ dig +time=2 +tries=1 @192.168.5.1 example.com
  #   ;; communications error to 192.168.5.1#53: timed out
  # 10.24.89.1 sits inside wg-home's allowedIPs, so it routes over the tunnel.
  #
  # wg-quick sorts non-IP entries into search domains rather than resolvers.
  # lan.1ella.com and dmz.1ella.com are served only by the UDM, so without
  # this tiger and cogsworth are reachable by address alone.
  dns = [
    "10.24.89.1"
    "lan.1ella.com"
    "dmz.1ella.com"
  ];

  # The two profiles differ only in allowedIPs, which is a client-side routing
  # decision, so both share one UniFi client and one key.
  mkInterface = allowedIPs: {
    inherit address dns;
    autostart = false;
    privateKeyFile = config.sops.secrets.trex_wireguard_private_key.path;
    peers = [
      {
        inherit allowedIPs endpoint;
        publicKey = serverPublicKey;
        persistentKeepalive = 25;
      }
    ];
  };

  interfaces = {
    # LAN, tiger's DMZ, and the tunnel subnet itself for DNS.
    wg-home = mkInterface [
      "10.24.89.0/24"
      "10.25.89.0/24"
      "192.168.5.0/24"
    ];
    wg-all = mkInterface [ "0.0.0.0/0" ];
  };

  vpn = pkgs.writeShellScriptBin "vpn" ''
    set -euo pipefail

    readonly WG_QUICK="${pkgs.wireguard-tools}/bin/wg-quick"
    readonly WG="${pkgs.wireguard-tools}/bin/wg"
    readonly SPLIT=wg-home
    readonly FULL=wg-all

    usage() {
      cat <<'EOF'
    Usage: vpn <home|all|down|status>

      home    split tunnel: LAN, DMZ and the tunnel subnet only
      all     full tunnel: everything routes through home
      down    drop whichever tunnel is up
      status  show handshake and transfer counters
    EOF
    }

    # wg-quick records the utun device it claimed, so the marker file is the
    # only reliable way to ask whether a named profile is up.
    active() {
      for iface in "$SPLIT" "$FULL"; do
        if [ -f "/var/run/wireguard/$iface.name" ]; then
          echo "$iface"
          return 0
        fi
      done
      return 1
    }

    up() {
      local want="$1" running
      if running=$(active); then
        if [ "$running" = "$want" ]; then
          echo "$want is already up"
          return 0
        fi
        echo "$running is up; run 'vpn down' first" >&2
        return 1
      fi
      sudo "$WG_QUICK" up "$want"
    }

    if [ $# -ne 1 ]; then
      usage >&2
      exit 1
    fi

    case "$1" in
      home) up "$SPLIT" ;;
      all) up "$FULL" ;;
      down)
        if running=$(active); then
          sudo "$WG_QUICK" down "$running"
        else
          echo "no tunnel is up"
        fi
        ;;
      status)
        if running=$(active); then
          # wg addresses the utun device, not the profile name: the socket it
          # looks for is named after the interface wg-quick actually claimed.
          echo "$running:"
          sudo "$WG" show all
        else
          echo "no tunnel is up"
        fi
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac
  '';
in
{
  sops.secrets = {
    # Read by wg-quick's PostUp, which runs as root under sudo.
    trex_wireguard_private_key = {
      mode = "0400";
    };
  };

  networking.wg-quick.interfaces = interfaces;

  home-manager.users.kyle.home.packages = [ vpn ];
}
