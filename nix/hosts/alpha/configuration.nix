{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  boot = {
    supportedFilesystems = [ "zfs" ];
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
  };
  networking = {
    hostName = "alpha";
    hostId = "3d7631ea";
    #defaultGateway = "10.24.89.1";
    #nameservers = [ "10.24.89.1" ]; # todo: set to localhost?
  };
  # don't sleep with lid closed
  services = {
    logind = {
      lidSwitch = "ignore";
      lidSwitchDocked = "ignore";
    };
    sanoid = {
      # we need to run sanoid to prune the backups
      enable = true;
      extraArgs = [
        "--verbose"
        "--prune-snapshots"
      ];
      datasets = {
        "storage/backups" = {
          autosnap = false;
          autoprune = true;
          hourly = 4;
          daily = 31;
          monthly = 24;
          yearly = 10;
        };
        "storage/photos" = {
          autosnap = false;
          autoprune = true;
          hourly = 0;
          daily = 8;
          monthly = 12;
          yearly = 0;
        };
      };
    };
    syncoid = {
      # had to run the following on alpha to get the service to work
      # > sudo -u syncoid ssh -i /var/lib/syncoid/id_ed25519 -p 2332 svc.syncoid@tiger.dmz.1ella.com

      # Had to run the following on tiger to grant the user the proper permissiosn
      # > sudo zfs allow -u svc.syncoid send,hold,mount,snapshot,destroy storage

      # syncoid crates ZFS snapshot, but we DO NOT mount these filesystems. If
      # we needed them for some reason, we mount the filesystem manually.
      enable = true;
      sshKey = /var/lib/syncoid/id_ed25519;
      commands = {
        "storage/photos" = {
          target = "storage/photos";
          source = "svc.syncoid@tiger.dmz.1ella.com:storage/photos";
          extraArgs = [ "--sshport" "2332" ];
        };
        "storage/backups" = {
          target = "storage/backups";
          source = "svc.syncoid@tiger.dmz.1ella.com:storage/backups";
          extraArgs = [ "--sshport" "2332" ];
        };
      };
    };
  };
  system.stateVersion = "23.05";

  systemFoundry = {
    dnsServer = {
      enable = true;
      blacklist.enable = false;

      upstreamDnsServers = [ "10.24.89.1" ];
      aRecords = {
        "util.lan.1ella.com" = "10.24.89.53"; # why?

        # monitoring
        "prometheus.apps.lan.1ella.com" = "10.24.89.5";
        "grafana.apps.lan.1ella.com" = "10.24.89.5";

        "local.1ella.com" = "127.0.0.1";
      };
      cnameRecords = { };
      domainRecords = {
        "dmz.1ella.com" = "10.25.89.5";
        "apps.dmz.1ella.com" = "10.25.89.5";
      };
    };
  };
  environment.systemPackages = with pkgs; [
    # for ZFS # TODO: scope to just hosts needed
    lzop
    mbuffer
  ];

  # TODO: add systemd service to check is we can resolve DNS from self, if not,
  #       restart dnsmasq. That fact that we hardcode the IP address is
  #       fragile, but it works for now. I really do need to figure out _why_
  #       this happens and fix the root issue.
  systemd.services.dnsmasq-watchdog = {
    enable = true;
    startAt = "*-*-* *:*:00"; # every minute
    path = with pkgs; [
      dnsutils
    ];
    script = ''
      set -x
      [[ -z $(dig @10.24.89.53 alpha.lan.1ella.com +short) ]] && systemctl restart dnsmasq || exit 0
    '';
  };
}
