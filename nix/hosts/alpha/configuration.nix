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
  services.logind = {
    lidSwitch = "ignore";
    lidSwitchDocked = "ignore";
  };
  system.stateVersion = "23.05";

  # TODO: add ZFS filesystems
  systemFoundry = {
    dnsServer = {
      enable = true;
      blacklist.enable = true;

      upstreamDnsServers = [ "10.24.89.1" ];
      aRecords = {
        "util.lan.509ely.com" = "10.24.89.53"; # why?

        # monitoring
        "prometheus.apps.lan.509ely.com" = "10.24.89.5";
        "grafana.apps.lan.509ely.com" = "10.24.89.5";
      };
      cnameRecords = { };
      domainRecords = {
        "dmz.509ely.com" = "10.25.89.5";
        "apps.dmz.509ely.com" = "10.25.89.5";
      };
    };
  };
}
