{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.deployment_target;
in
{
  options.systemFoundry.deployment_target = {
    enable = mkEnableOption ''
      Basic configuration which allows the node to be comply with assumptions I
      made about the target node.

      This is also a kind of catch all when I want to unilaterally deploy
      something out to all managed nodes. I try to keep this as minimal as I
      can, just enough to get connectivity to deploy the rest of the
      configuration. Due to this, some of the configuration in here will de
      duplicated by other modules.

      This only gets applied to NixOS nodes.
    '';
  };

  config = mkIf cfg.enable {

    environment.systemPackages = with pkgs; [
      git # working this repos locally
      molly-guard # prevent footguns from runing my day
      neovim # file editing
      rsync # syncing files
      smartmontools # drive health checks
    ];

    # Preemptive SMART monitoring on all managed nodes. Autodetects all drives,
    # runs short daily self-tests and long weekly tests. Logs problems to
    # syslog/journald (promtail picks them up and forwards to Loki).
    services.smartd = {
      enable = lib.mkDefault true; # hosts with no SMART drives (e.g. SD-card Pi) should set this false
      autodetect = true;
      defaults.monitored = "-a -o on -s (S/../.././02|L/../../6/03)";
    };

    # Export SMART health as Prometheus textfile metrics so vmalert can alert on them.
    # Scans all drives every 15 minutes and writes smartctl_device_smart_healthy{device=...}
    # (1=healthy, 0=failed) to the node_exporter textfile directory.
    systemd.tmpfiles.rules = [
      "d /var/lib/prometheus-node-exporter-text-files 0755 root root -"
    ];

    systemd.timers.smartctl-exporter = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "15min";
        Persistent = true;
      };
    };

    users = {
      defaultUserShell = pkgs.bashInteractive;
      mutableUsers = false;
      users."svc.deploy" = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        hashedPassword = "$6$XTNiJhQm1$D3M90syVNZdTazCOZIAF8TLK/hD4oSi3Xdst62dCkWR44ia3rujnPx.yWT6BaU4tvu1im5nR20WcjWnhPMTIV/";
        # todo: make a key for just deploys
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKtqba65kXXovFMhf0fR02pTlBJ8/w1bj24wqJuQmUZ+ kyle@dino"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIACXOhBDxjR0LAbLo0oIPSC9yY4ni7aoZB7Mt+WJ/GpU root@dino" # for nix distributed builds
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINgcHG0ylxjju9yXvUtoS/roqfB1iPd/sFbmxCMUJkb/ root@elk"
        ];
      };
    };
    services = {
      openssh = {
        enable = true;
        settings = {
          PermitRootLogin = "no";
          AcceptEnv = "LANG LC_*";
        };
      };
      # TODO: do I still need RuntimeDirectorySize?
      logind.settings.Login.RuntimeDirectorySize = "8G";
    };

    nixpkgs.config.allowUnfree = true;
    nix = {
      package = pkgs.nixVersions.latest;
      settings = {
        trusted-users = [
          "root"
          "@wheel"
        ]; # todo: security issue?
        trusted-substituters = [ "ssh://svc.deploy@tiger.dmz.1ella.com" ];
        auto-optimise-store = true;
        download-buffer-size = 524288000; # 500 MB
        connect-timeout = 5;
        stalled-download-timeout = 30;
        download-attempts = 3;
        substituters = [
          "https://cache.apps.ondy.org"
          "https://cache.nixos.org"
        ];
        trusted-public-keys = [
          "cache.apps.ondy.org-1:7HWTVdm4uIcOykyNwsKsEjRqqOzuLqK12//JXLiUU7I="
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        ];
      };
      nixPath = [ "nixpkgs=${pkgs.path}" ];
      extraOptions = ''
        experimental-features = nix-command flakes
      '';
    };
    security.sudo.wheelNeedsPassword = false;

    # Prevent critical services from restarting during activation.
    #
    # sshd: deploy-rs uses the SSH connection to confirm deployment. If sshd
    # restarts, the connection drops, causing timeouts and automatic rollback.
    #
    # WireGuard: Hosts with NFS mounts over WireGuard hang during
    # daemon-reexec when the tunnel goes down — the NFS unmount blocks systemd.
    # Both the interface and peer services must be pinned — removing a peer tears
    # down the tunnel even when the interface stays up.
    #
    # Changes to these services take effect on next reboot.
    systemd.services = {
      sshd = {
        restartIfChanged = false;
        restartTriggers = lib.mkForce [ ];
      };
      smartctl-exporter = {
        description = "Export SMART drive health to node_exporter textfile";
        serviceConfig = {
          Type = "oneshot";
          User = "root";
        };
        path = with pkgs; [
          smartmontools
          gawk
          gnugrep
          coreutils
        ];
        script = ''
          set -euo pipefail
          OUTFILE="/var/lib/prometheus-node-exporter-text-files/smartctl_health.prom"
          {
            printf '# HELP smartctl_device_smart_healthy SMART overall health (1=healthy, 0=failed)\n'
            printf '# TYPE smartctl_device_smart_healthy gauge\n'
            while IFS= read -r device_line; do
              device=$(awk '{print $1}' <<< "$device_line")
              devtype=$(awk '{print $3}' <<< "$device_line")
              devname=$(basename "$device")
              exit_code=0
              health=$(smartctl -H -d "$devtype" "$device" 2>&1) || exit_code=$?
              if grep -qE 'PASSED|result: OK' <<< "$health"; then
                status=1
              elif grep -qE 'FAILED' <<< "$health"; then
                status=0
              elif [[ $((exit_code & 4)) -ne 0 ]] || [[ $((exit_code & 8)) -ne 0 ]]; then
                status=0
              else
                continue
              fi
              printf 'smartctl_device_smart_healthy{device="%s"} %d\n' "$devname" "$status"
            done < <(smartctl --scan)
          } > "$OUTFILE.tmp"
          mv "$OUTFILE.tmp" "$OUTFILE"
        '';
      };
    }
    // lib.optionalAttrs (config.networking.wireguard.interfaces ? wg0) (
      {
        wireguard-wg0 = {
          restartIfChanged = false;
          restartTriggers = lib.mkForce [ ];
        };
      }
      // lib.listToAttrs (
        map (
          peer:
          lib.nameValuePair "wireguard-wg0-peer-${peer.name}" {
            restartIfChanged = false;
            restartTriggers = lib.mkForce [ ];
          }
        ) config.networking.wireguard.interfaces.wg0.peers
      )
    );

    # this file path _feels_ suspect, but works
    sops.defaultSopsFile = ./../../secrets/secrets.yaml;

    networking.firewall.allowedTCPPorts = [
      # TODO: I don't think we need these ports open
      # 80 # http
      # 443 # http
    ];
    networking.firewall.enable = false; # TODO: why is this not true?
    #services.nginx = {
    #  enable = true;
    #  # todo: return a more bare page
    #  virtualHosts."default".default = true;
    #  # todo: can I pass in the full domain name here?
    #  # todo: add basic auth
    #};
    # todo: add in old stuff
    #systemFoundry.nginxReverseProxy = {
    #  enable = true;
    #  domainName = "${config.networking.hostName}.*";
    #  proxyPass = "http://127.0.0.1:9002/metrics";
    #};

    #######################################################################
    # TODO: refactor out below configuration into more generic modules
    #######################################################################
    programs = {
      # TODO: why?
      systemtap.enable = true;
    };
    security = {
      acme = {
        # TODO: acme being here feels very wrong
        # so I do not need to set it in every module
        acceptTerms = true;
        defaults = {
          email = "kyle@ondy.org";
          dnsProvider = "namecheap";
          environmentFile = config.sops.secrets.namecheap.path;
        };
      };
    };
    # todo: fix: need to create an acme user and group to get the deploy working
    users.users.acme = {
      isSystemUser = true;
      group = "acme";
    };
    # /fix
    users.groups.acme = { };
  };
}
