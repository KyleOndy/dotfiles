# Do not modify this file!  It was generated by ‘nixos-generate-config’
# and may be overwritten by future invocations.  Please make changes
# to /etc/nixos/configuration.nix instead.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ ];

  boot.initrd.availableKernelModules = [ "ata_piix" "floppy" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    {
      device = "/dev/disk/by-uuid/f302c19e-efd8-4527-9893-171f7e828288";
      fsType = "ext4";
    };

  swapDevices =
    [{ device = "/dev/disk/by-uuid/8695ed22-9304-445d-a1b5-398207166b6e"; }];

  virtualisation.hypervGuest.enable = true;
}