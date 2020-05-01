# This is a catchall for configuration items that are common across all
# machines and at this time do not make sense to break out into their own file.
{ config, pkgs, ... }:

{
  boot.kernelModules = [ "kvm-amd" "kvm-intel" ];
  virtualisation.libvirtd.enable = true;
}
