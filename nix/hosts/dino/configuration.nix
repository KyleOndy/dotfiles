{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:
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
  boot.kernelModules = [
    "kvm-intel"
    "kvm-amd"
  ];

  # Framework 12th gen: Fix suspend battery drain
  # Reduces suspend power consumption from ~20-40%/8hrs to ~1%/hour
  boot.kernelParams = [
    "acpi_osi=\"!Windows 2020\""
    "mem_sleep_default=deep" # Enable deeper S3 sleep state for better power savings
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

      # Audio power management
      SOUND_POWER_SAVE_ON_AC = 1;
      SOUND_POWER_SAVE_ON_BAT = 10;

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

  # KVM virtualization support
  virtualisation.libvirtd.enable = true;

  # QEMU bridge configuration for VM networking
  environment.etc."qemu/bridge.conf" = {
    text = ''
      allow all
    '';
  };

  # === Configuration from common.nix ===

  # Timezone and locale
  time.timeZone = "America/New_York";
  i18n = {
    defaultLocale = "en_US.UTF-8";
  };
  console = {
    useXkbConfig = true;
  };

  # Base system packages
  environment.systemPackages = with pkgs; [
    curl
    gitAndTools.git
    gnumake
    rsync
    neovim
    powertop # Power consumption and management diagnosis tool
  ];

  environment.pathsToLink = [
    "/libexec"
    "/share/zsh"
  ];

  # X server and desktop configuration
  services.xserver = {
    enable = true;
    xkb = {
      options = "ctrl:nocaps";
    };
    desktopManager = {
      xterm.enable = false;
    };
  };

  # udev rules
  services.udev = {
    packages = [ pkgs.yubikey-personalization ];
    extraRules = ''
      # UDEV rules for Teensy USB devices
      ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789B]?", ENV{ID_MM_DEVICE_IGNORE}="1"
      ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789A]?", ENV{MTP_NO_PROBE}="1"
      SUBSYSTEMS=="usb", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789ABCD]?", MODE:="0666"
      KERNEL=="ttyACM*", ATTRS{idVendor}=="16c0", ATTRS{idProduct}=="04[789B]?", MODE:="0666"
    '';
  };

  # System services
  services.pcscd.enable = true;
  services.openssh.enable = true;
  services.fstrim.enable = true;
  services.printing = {
    enable = true;
    drivers = [ pkgs.hplip ];
  };

  # Programs configuration
  programs.ssh.startAgent = false;
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };
  programs.mosh.enable = true;
  programs.less = {
    enable = true;
    envVariables = {
      LESS = "--quit-if-one-screen --RAW-CONTROL-CHARS --no-init";
    };
  };

  # Boot configuration
  boot.tmp = {
    cleanOnBoot = true;
    useTmpfs = true;
  };

  # Nix configuration
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 35d";
  };
  nix.settings = {
    auto-optimise-store = true;
  };
  nix.extraOptions = ''
    experimental-features = nix-command flakes
    min-free = ${toString (1 * 1024 * 1024 * 1024)}
    max-free = ${toString (25 * 1024 * 1024 * 1024)}
    keep-derivations = true
    keep-outputs = true
  '';

  # VM variant configuration
  virtualisation.vmVariant = {
    virtualisation = {
      memorySize = 4096;
      cores = 4;
    };
  };

  # Remote build machines
  systemFoundry.nixBuilders = {
    enable = true;
    machines = [
      {
        hostName = "tiger.dmz.1ella.com";
        sshUser = "svc.deploy";
        systems = [
          "x86_64-linux"
          "aarch64-linux"
        ];
        maxJobs = 8;
        speedFactor = 10;
        supportedFeatures = [
          "benchmark"
          "big-parallel"
        ];
      }
      {
        hostName = "cheetah";
        sshUser = "svc.deploy";
        systems = [
          "x86_64-linux"
          "aarch64-linux"
        ];
        maxJobs = 4;
        speedFactor = 10;
        supportedFeatures = [
          "benchmark"
          "big-parallel"
        ];
      }
    ];
  };

  # Docker
  systemFoundry.docker.enable = true;

  # Power management - disable conflicting service
  services.power-profiles-daemon.enable = false; # using tlp instead

  # Framework 13 DSP support
  programs.dconf.enable = true;

  # Dino-specific home-manager user configuration
  home-manager.users.kyle = {
    hmFoundry = {
      shell.starship.enable = true;
      desktop = {
        media.latex.enable = true;
        wm.kde.enable = true;
      };
      dev = {
        terraform.enable = lib.mkForce true;
        claude-code = {
          enable = true;
          enableNotifications = true;
        };
      };
    };
    # Framework 13 DSP audio configuration
    services.easyeffects.enable = true;
    xdg.configFile."easyeffects/output/cab-fw.json".source =
      "${inputs.framework-dsp}/config/output/Gracefu's Edits.json";
  };
}
