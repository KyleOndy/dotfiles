{ config, pkgs, lib, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  networking = {
    hostName = "cheetah";
  };

  boot.binfmt.emulatedSystems = [ "aarch64-linux" "armv7l-linux" ];
}
