### http://nixos.org/channels/nixos-unstable nixos

{ config, pkgs, ... }:
{
  fileSystems = {
    "/" = {
      device = "/dev/null";
      fsType = "ext4";
    };
  };
  #boot.loader.grub = {
  #  enable = true;
  #  version = 2;
  #  device = "/dev/nvme0n1";
  #};
  security.sudo.wheelNeedsPassword = false;
  environment.systemPackages = with pkgs; [
    htop
    glances
  ];
}
