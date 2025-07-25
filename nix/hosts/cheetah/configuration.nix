{ config, pkgs, lib, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  networking = {
    hostName = "cheetah";
  };

  boot.binfmt.emulatedSystems = [ "aarch64-linux" "armv7l-linux" ];

  # Configure mdadm to send notifications to root for RAID events
  boot.swraid.mdadmConf = "MAILADDR root@localhost";

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.05";
}
