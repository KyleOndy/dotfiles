{ config, pkgs, lib, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  networking = {
    hostName = "cheetah";
  };
}
