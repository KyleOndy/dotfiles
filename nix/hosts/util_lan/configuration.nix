{ config, pkgs, lib, ... }:

{
  boot.supportedFilesystems = [ "zfs" ];
  networking = {
    hostName = "util";
    hostId = "3d4638ea";
    defaultGateway = "10.24.89.1";
    nameservers = [ "10.24.89.1" ]; # todo: set to localhost?
    interfaces.eth0.useDHCP = true;
  };

  # Assuming this is installed on top of the disk image.
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
      options = [ "noatime" ];
    };
    #"/mnt/media" = {
    #  device = "storage/media";
    #  fsType = "zfs";
    #  #options = [ "zfsutil" ]; # why?
    #};
    #"/mnt/backups" = {
    #  device = "storage/backups";
    #  fsType = "zfs";
    #  #options = [ "zfsutil" ]; # why?
    #};
    #"/mnt/scratch" = {
    #  device = "storage/scratch";
    #  fsType = "zfs";
    #  #options = [ "zfsutil" ]; # why?
    #};
  };

  powerManagement.cpuFreqGovernor = "ondemand";
  system.stateVersion = "20.09";

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
