{ config, pkgs, ... }:
{
  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.blacklistedKernelModules = [
    "hid_sensor_hub"
  ];



  # becuase we are dual booting
  time.hardwareClockInLocalTime = true;

  networking.hostName = "dino"; # Define your hostname.
  networking.wireless.enable = true;
  system.stateVersion = "22.05";
}

