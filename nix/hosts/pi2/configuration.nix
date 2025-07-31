{
  config,
  pkgs,
  lib,
  ...
}:

{
  networking = {
    hostName = "pi2";
    interfaces.eth0.useDHCP = true;
  };

  # Assuming this is installed on top of the disk image.
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
      options = [ "noatime" ];
    };
  };
  powerManagement.cpuFreqGovernor = "ondemand";
  system.stateVersion = "20.09";
}
