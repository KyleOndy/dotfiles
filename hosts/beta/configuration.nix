{ config, pkgs, ... }:

{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ./../_includes/common.nix
    ./../_includes/docker.nix
    ./../_includes/kyle.nix
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "beta";
  networking.networkmanager.enable = true;

  hardware = { cpu.intel.updateMicrocode = true; };

  users.mutableUsers = false;

  system.stateVersion = "19.09"; # Did you read the comment?

}
