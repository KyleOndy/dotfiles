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

  # Enable Framework battery charge control via cros_charge-control driver
  # Required for TLP 1.8+ to manage battery thresholds on Framework laptops
  # This allows TLP to communicate with the ChromeOS-derived EC to enforce charge limits
  boot.extraModprobeConfig = ''
    options cros_charge_control probe_with_fwk_charge_control=1
  '';

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

  # SOPS secrets for WiFi configuration and monitoring
  sops.secrets = {
    home_wifi_ssid = { };
    home_wifi_password = { };
    monitoring_token_dino = {
      # vmagent service runs as DynamicUser, which means it can't be assigned
      # file ownership directly. Using mode 0444 allows the service to read it.
      # This is acceptable since the token is only used for authentication to
      # our own VictoriaMetrics instance, not external services.
      mode = "0444";
    };
    email_kyle_ondy_org = {
      owner = "kyle";
      mode = "0400";
    };
    email_kyle_ondy_me = {
      owner = "kyle";
      mode = "0400";
    };
    email_kyleondy_gmail = {
      owner = "kyle";
      mode = "0400";
    };
  };

  sops.templates."nm-home-wifi-env" = {
    content = ''
      HOME_WIFI_SSID="${config.sops.placeholder.home_wifi_ssid}"
      HOME_WIFI_PASSWORD="${config.sops.placeholder.home_wifi_password}"
    '';
  };

  # Password script for automated mbsync service
  sops.templates."mbsync-password-script" = {
    owner = "kyle";
    mode = "0500";
    content = ''
      #!/usr/bin/env bash
      set -euo pipefail
      case "$1" in
        "kyle@ondy.org")
          cat ${config.sops.secrets.email_kyle_ondy_org.path}
          ;;
        "kyle@ondy.me")
          cat ${config.sops.secrets.email_kyle_ondy_me.path}
          ;;
        "kyleondy@gmail.com")
          cat ${config.sops.secrets.email_kyleondy_gmail.path}
          ;;
        *)
          echo "Unknown email account: $1" >&2
          exit 1
          ;;
      esac
    '';
  };

  # Automated mbsync config for systemd service (uses sops passwords)
  sops.templates."mbsyncrc-automated" = {
    owner = "kyle";
    mode = "0600";
    content = ''
      # Generated mbsync config for automated systemd service
      # Uses sops-encrypted passwords instead of pass/GPG

      IMAPAccount kyle_at_ondy_org
      CertificateFile /etc/ssl/certs/ca-certificates.crt
      Host london.mxroute.com
      PassCmd "bash ${config.sops.templates."mbsync-password-script".path} kyle@ondy.org"
      TLSType IMAPS
      User kyle@ondy.org

      IMAPStore kyle_at_ondy_org-remote
      Account kyle_at_ondy_org

      MaildirStore kyle_at_ondy_org-local
      Inbox /home/kyle/mail/ondy.org/Inbox
      Path /home/kyle/mail/ondy.org/
      SubFolders Verbatim

      Channel kyle_at_ondy_org
      Create Near
      Expunge None
      Far :kyle_at_ondy_org-remote:
      Near :kyle_at_ondy_org-local:
      Patterns INBOX Archive "Deleted Messages" Drafts Junk Sent
      Remove None
      SyncState *
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

    # Thunderbolt support for CalDigit TS4 dock
    # Enables authorization of Thunderbolt devices via boltctl
    hardware.bolt.enable = true;
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
      # Framework laptops only support stop threshold (end threshold)
      # Battery is at BAT1 (not BAT0) with cros_charge_control driver
      # Set START to 0 to use only stop threshold (per TLP docs)
      START_CHARGE_THRESH_BAT1 = 0;
      STOP_CHARGE_THRESH_BAT1 = 97;
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
    bolt # Thunderbolt device management for CalDigit TS4 dock
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

      # CalDigit TS4 Thunderbolt dock - start sleep inhibitor when connected
      # Trigger on Thunderbolt device add/remove events for CalDigit vendor
      ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{device_name}=="TS4", ATTR{vendor_name}=="CalDigit, Inc.", TAG+="systemd", ENV{SYSTEMD_WANTS}="inhibit-sleep-when-docked.service"
      ACTION=="remove", SUBSYSTEM=="thunderbolt", ATTR{device_name}=="TS4", ATTR{vendor_name}=="CalDigit, Inc.", RUN+="${pkgs.systemd}/bin/systemctl stop inhibit-sleep-when-docked.service"
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

  # Prevent system sleep when CalDigit TS4 dock is connected
  # This ensures the laptop stays awake while docked, even if lid is closed
  # Triggered by udev rules when dock connects/disconnects
  systemd.services.inhibit-sleep-when-docked =
    let
      monitorScript = pkgs.writeShellScript "monitor-dock-connected" ''
        #!/usr/bin/env bash
        set -euo pipefail

        echo "$(date): CalDigit dock connected, holding sleep inhibitor"

        # Monitor dock connection status
        while true; do
          DOCK_INFO=$(${pkgs.bolt}/bin/boltctl list 2>/dev/null || true)

          if echo "$DOCK_INFO" | ${pkgs.gnugrep}/bin/grep -q "CalDigit" && \
             echo "$DOCK_INFO" | ${pkgs.gnugrep}/bin/grep -A10 "CalDigit" | ${pkgs.gnugrep}/bin/grep -qE "status:[[:space:]]+connected$"; then
            # Still connected, keep holding inhibitor
            sleep 10
          else
            # Dock disconnected, exit to release inhibitor
            echo "$(date): CalDigit dock disconnected, releasing sleep inhibitor"
            exit 0
          fi
        done
      '';
    in
    {
      description = "Inhibit sleep when CalDigit TS4 Thunderbolt dock is connected";
      # Service is triggered by udev rules, not started at boot
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=sleep:handle-lid-switch --who='CalDigit TS4 Dock Monitor' --why='Prevent sleep while docked' --mode=block ${monitorScript}";
        Restart = "on-failure";
      };
    };

  # Monitoring stack configuration
  systemFoundry.monitoringStack = {
    enable = true;

    # Enable node exporter for system metrics
    nodeExporter.enable = true;

    # Send metrics to wolf's VictoriaMetrics instance
    vmagent = {
      enable = true;
      remoteWriteUrl = "https://metrics.apps.ondy.org/api/v1/write";
      bearerTokenFile = config.sops.secrets.monitoring_token_dino.path;
      scrapeConfigs = [
        {
          job_name = "node";
          static_configs = [
            {
              targets = [ "127.0.0.1:9100" ];
              labels = {
                host = "dino";
              };
            }
          ];
        }
      ];
    };

    # Send logs to wolf's Loki instance
    promtail = {
      enable = true;
      lokiUrl = "https://loki.apps.ondy.org/loki/api/v1/push";
      bearerTokenFile = config.sops.secrets.monitoring_token_dino.path;
      extraLabels = {
        host = "dino";
      };
    };
  };

  # Notmuch mail indexing service (runs after mbsync)
  systemd.user.services.notmuch-new = {
    description = "Notmuch mail indexer";
    after = [ "mbsync.service" ];
    serviceConfig = {
      Type = "oneshot";
      # Use --no-hooks since mbsync is handled by separate service
      ExecStart = "${pkgs.notmuch}/bin/notmuch new --no-hooks";
      WorkingDirectory = "/home/kyle";
      StandardOutput = "journal";
    };
  };

  # Timer to run notmuch after mbsync completes
  systemd.user.timers.notmuch-new = {
    description = "Notmuch mail indexing timer";
    timerConfig = {
      OnCalendar = "*:0/15"; # Every 15 minutes, matching mbsync
      Persistent = true;
    };
    wantedBy = [ "timers.target" ];
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
        hostName = "wolf";
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

  # Professional audio/video devices (MOTU M4, Elgato)
  systemFoundry.audioVideoDevices.enable = true;

  # Power management - disable conflicting service
  services.power-profiles-daemon.enable = false; # using tlp instead

  # Framework 13 DSP support
  programs.dconf.enable = true;

  # Configure systemd-logind to let KDE PowerDevil handle power button
  # Otherwise logind intercepts power button before KDE can handle it
  services.logind.extraConfig = ''
    HandlePowerKey=ignore
  '';

  # Dino-specific home-manager user configuration
  home-manager.users.kyle = {
    hmFoundry = {
      desktop = {
        apps.zoom.enable = true;
        apps.teams.enable = true;
        media.latex.enable = true;
        wm.kde.enable = true;
        gaming.emulators.enable = true;
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

    # Power management configuration for laptop
    programs.plasma.powerdevil = {
      AC = {
        autoSuspend = {
          action = "nothing"; # Don't auto-suspend when on AC
        };
        turnOffDisplay = {
          idleTimeout = 600; # Turn off display after 10 minutes (in seconds)
          idleTimeoutWhenLocked = 60; # Turn off display 1 min after lock
        };
        dimDisplay = {
          enable = true;
          idleTimeout = 540; # Dim after 9 minutes (before display turns off)
        };
        whenLaptopLidClosed = "sleep"; # Still sleep when lid closes
        inhibitLidActionWhenExternalMonitorConnected = true; # Don't sleep with external monitor
        powerButtonAction = "nothing"; # Prevent race condition when waking from sleep
      };

      battery = {
        autoSuspend = {
          action = "sleep"; # Auto-suspend when on battery
          idleTimeout = 300; # After 5 minutes of inactivity
        };
        turnOffDisplay = {
          idleTimeout = 180; # Turn off display after 3 minutes
          idleTimeoutWhenLocked = 30; # Turn off display 30s after lock
        };
        dimDisplay = {
          enable = true;
          idleTimeout = 120; # Dim after 2 minutes
        };
        whenLaptopLidClosed = "sleep";
        powerButtonAction = "nothing"; # Prevent race condition when waking from sleep
      };

      lowBattery = {
        autoSuspend = {
          action = "sleep"; # Aggressive sleep when battery is low
          idleTimeout = 120; # After 2 minutes of inactivity
        };
        turnOffDisplay = {
          idleTimeout = 60; # Turn off display after 1 minute
          idleTimeoutWhenLocked = 20; # Turn off display 20s after lock (minimum allowed)
        };
        dimDisplay = {
          enable = true;
          idleTimeout = 30; # Dim after 30 seconds
        };
        whenLaptopLidClosed = "sleep";
        powerButtonAction = "nothing"; # Prevent race condition when waking from sleep
      };

      batteryLevels = {
        lowLevel = 20; # Low battery at 20%
        criticalLevel = 5; # Critical battery at 5%
        criticalAction = "sleep"; # Sleep at critical battery
      };
    };

    # Override mbsync service to use sops-based config for automated runs
    systemd.user.services.mbsync.Service.ExecStart = lib.mkForce "${pkgs.isync}/bin/mbsync -c ${
      config.sops.templates."mbsyncrc-automated".path
    } --all";
  };
}
