{ config, pkgs, ... }:
{
  # Use the systemd-boot EFI boot loader.
  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    blacklistedKernelModules = [
      "hid_sensor_hub"
    ];
    binfmt.emulatedSystems = [
      "aarch64-linux"
      "armv7l-linux"
    ];
  };

  boot.initrd.luks.device."crypted" = {
    device = "/dev/disk/by-partlabel/disk-main-luks";
    allowDiscards = true;
  };

  fileSystems."/" = {
    device = "/dev/mapper/crypted";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/disk-main-ESP";
    fsType = "vfat";
    options = [
      "fmask=0022"
      "dmask=0022"
    ];
  };

  boot.initrd.availableKernelModules = [
    "xhci_pci" # USB 3.0
    "nvme" # NVMe SSD
    "usb_storage" # usb storage
    "sd_mod" # sd card
    "thunderbolt"
  ];

  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];

  # becuase we are dual booting
  time.hardwareClockInLocalTime = true;

  networking.hostName = "dino"; # Define your hostname.
  system.stateVersion = "24.05";

  networking.networkmanager = {
    enable = true;
  };

  security.rtkit.enable = true;
  services = {
    pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };
    fwupd.enable = true;
    libinput.touchpad.disableWhileTyping = true;
  };
  hardware = {
    bluetooth = {
      enable = true;
      powerOnBoot = true;
    };
    keyboard.zsa.enable = true;
  };
}
