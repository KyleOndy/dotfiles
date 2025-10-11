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

  boot.initrd.luks.devices."crypted" = {
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

  # Framework 12th gen: Fix suspend battery drain
  # Reduces suspend power consumption from ~20-40%/8hrs to ~1%/hour
  boot.kernelParams = [
    "acpi_osi=\"!Windows 2020\""
  ];

  networking.hostName = "dino"; # Define your hostname.
  system.stateVersion = "24.05";

  networking.networkmanager = {
    enable = true;
    ensureProfiles = {
      environmentFiles = [
        config.sops.templates."nm-home-wifi-env".path
      ];
      profiles = {
        home-wifi = {
          connection = {
            id = "Home WiFi";
            type = "802-11-wireless";
            autoconnect = true;
          };
          "802-11-wireless" = {
            mode = "infrastructure";
            ssid = "$HOME_WIFI_SSID";
          };
          "802-11-wireless-security" = {
            auth-alg = "open";
            key-mgmt = "wpa-psk";
            psk = "$HOME_WIFI_PASSWORD";
          };
          ipv4 = {
            method = "auto";
          };
          ipv6 = {
            method = "auto";
          };
        };
      };
    };
  };

  # SOPS secrets for WiFi configuration
  sops.secrets = {
    home_wifi_ssid = { };
    home_wifi_password = { };
  };

  sops.templates."nm-home-wifi-env" = {
    content = ''
      HOME_WIFI_SSID="${config.sops.placeholder.home_wifi_ssid}"
      HOME_WIFI_PASSWORD="${config.sops.placeholder.home_wifi_password}"
    '';
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
    enableRedistributableFirmware = true;
    bluetooth = {
      enable = true;
      powerOnBoot = false; # Save power - enable manually when needed
    };
    keyboard.zsa.enable = true;
  };

  # Power management for Framework 12th gen laptop
  powerManagement = {
    enable = true;
    #cpuFreqGovernor = null;
    # Enable PowerTop auto-tuning
    powertop.enable = true;
  };

  # Intel thermal management daemon
  # Proactively prevents overheating and works well with TLP
  services.thermald.enable = true;

  services.tlp = {
    enable = true;
    settings = {
      # CPU Settings
      CPU_BOOST_ON_BAT = 0;
      CPU_BOOST_ON_AC = 1;
      CPU_SCALING_GOVERNOR_ON_AC = "powersave";
      CPU_SCALING_GOVERNOR_ON_BAT = "powersave";

      # Intel P-state performance settings (12th gen Alder Lake)
      CPU_ENERGY_PERF_POLICY_ON_AC = "performance";
      CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
      CPU_MIN_PERF_ON_AC = 0;
      CPU_MAX_PERF_ON_AC = 100;
      CPU_MIN_PERF_ON_BAT = 0;
      CPU_MAX_PERF_ON_BAT = 30; # Cap CPU at 30% on battery for better battery life

      # PCIe ASPM (Active State Power Management)
      PCIE_ASPM_ON_AC = "default";
      PCIE_ASPM_ON_BAT = "powersupersave"; # Enables L1.2 low-power states

      # Runtime Power Management
      RUNTIME_PM_ON_AC = "on";
      RUNTIME_PM_ON_BAT = "auto";

      # NVMe power management
      AHCI_RUNTIME_PM_ON_AC = "on";
      AHCI_RUNTIME_PM_ON_BAT = "auto";
      AHCI_RUNTIME_PM_TIMEOUT = 15;

      # WiFi power saving
      WIFI_PWR_ON_AC = "off";
      WIFI_PWR_ON_BAT = "on";

      # USB autosuspend
      USB_AUTOSUSPEND = 1;
      USB_EXCLUDE_BTUSB = 0;
      USB_EXCLUDE_PHONE = 0;
      USB_EXCLUDE_PRINTER = 1;
      USB_EXCLUDE_WWAN = 0;

      # Battery charge thresholds (preserve battery health)
      START_CHARGE_THRESH_BAT0 = 90;
      STOP_CHARGE_THRESH_BAT0 = 97;
    };
  };
}
