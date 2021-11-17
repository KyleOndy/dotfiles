{ config, pkgs, ... }:
{
  imports =
    [ ./hardware-configuration.nix ];
  boot.loader.grub = {
    enable = true;
    version = 2;
    device = "/dev/sda";
  };
  networking = {
    hostName = "m1";
    useDHCP = false;
    interfaces.eth0.useDHCP = true;
  };
  system.stateVersion = "21.11"; # Did you read the comment?
}
