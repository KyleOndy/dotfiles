{ config, pkgs, ... }:
{
  # Use the systemd-boot EFI boot loader.
  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    blacklistedKernelModules = [
      "hid_sensor_hub"
    ];
    binfmt.emulatedSystems = [ "aarch64-linux" "armv7l-linux" ];
  };

  # becuase we are dual booting
  time.hardwareClockInLocalTime = true;
  services.fwupd.enable = true;

  networking.hostName = "dino"; # Define your hostname.
  system.stateVersion = "22.05";

  networking.networkmanager = {
    enable = true;
  };

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
}

