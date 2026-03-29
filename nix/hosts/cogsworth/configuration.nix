{
  config,
  pkgs,
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    # SD card image builder for aarch64
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
  ];

  # Sops configuration - use pre-baked SSH host key for decryption
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # WiFi credentials from sops
  sops.secrets.home_wifi_ssid = { };
  sops.secrets.home_wifi_password = { };
  sops.secrets.monitoring_token_cogsworth = {
    # vmagent/promtail use DynamicUser, need world-readable
    mode = "0444";
  };

  # wpa_supplicant secrets file template
  sops.templates."wpa-secrets".content = ''
    home_psk=${config.sops.placeholder.home_wifi_password}
  '';

  networking = {
    hostName = "cogsworth";
    # wpa_supplicant for WiFi with sops-encrypted credentials
    wireless = {
      enable = true;
      secretsFile = config.sops.templates."wpa-secrets".path;
      networks = {
        "The Ondy's" = {
          pskRaw = "ext:home_psk";
        };
      };
    };
  };

  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # Workaround for https://github.com/NixOS/nixpkgs/issues/154163
  # Generic aarch64 SD image includes modules not in RPi kernel
  nixpkgs.overlays = [
    (final: super: {
      makeModulesClosure = x: super.makeModulesClosure (x // { allowMissing = true; });
    })
  ];

  # SD image optimizations
  sdImage.compressImage = false; # Faster builds
  boot.supportedFilesystems.zfs = lib.mkForce false; # Not needed, speeds up build

  # Reduce SD card wear by disabling access time updates
  fileSystems."/" = lib.mkForce {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [
      "noatime"
      "nodiratime"
    ];
  };

  # Mount /tmp as tmpfs - reduces SD card wear and matches current system state
  boot.tmp = {
    cleanOnBoot = true;
    useTmpfs = true;
  };

  # Embed SSH host keys in SD image
  # NOTE: SSH key must be in image before boot because sops-nix uses it to decrypt other secrets.
  # The key is decrypted locally by the Makefile and passed via COGSWORTH_SSH_KEY env var
  # to avoid needing sops keys in the (potentially remote) build sandbox.
  sdImage.populateRootCommands =
    let
      # Read decrypted private key from environment (requires --impure)
      privateKeyContent = builtins.getEnv "COGSWORTH_SSH_KEY";
    in
    lib.mkAfter ''
      mkdir -p ./files/etc/ssh
      # Write private key from environment variable
      cat > ./files/etc/ssh/ssh_host_ed25519_key <<'EOF'
      ${privateKeyContent}
      EOF
      # Copy public key from store
      cp ${./keys/ssh_host_ed25519_key.pub} ./files/etc/ssh/ssh_host_ed25519_key.pub
      chmod 600 ./files/etc/ssh/ssh_host_ed25519_key
      chmod 644 ./files/etc/ssh/ssh_host_ed25519_key.pub
    '';

  # Disable rainbow splash and enable I2S audio
  # Note: UART4 for SEN0557 is configured via deviceTree overlay below
  sdImage.populateFirmwareCommands = lib.mkAfter ''
    chmod +w ./firmware/config.txt
    echo "disable_splash=1" >> ./firmware/config.txt
    echo "dtparam=i2s=on" >> ./firmware/config.txt
  '';

  # GPU drivers (creates /run/opengl-driver for mesa/GBM)
  hardware.graphics.enable = true;

  # Raspberry Pi 4 GPU configuration
  hardware.raspberry-pi."4" = {
    fkms-3d.enable = true; # V3D renderer for GPU acceleration

    # Firmware boot splash (shows during bootloader/firmware stage)
    apply-overlays-dtmerge.enable = true;

    # Enable ARM I2C bus on GPIO pins 3 (SDA) and 5 (SCL), available at /dev/i2c-1
    i2c1.enable = true;

    # Enable GPIO access with proper udev rules and iomem=relaxed kernel param
    gpio.enable = true;
  };

  # Enable UART4 on GPIO8/9 (pins 24/21) for SEN0557 sensor
  hardware.deviceTree.overlays = [
    {
      name = "uart4-complete";
      dtsText = ''
        /dts-v1/;
        /plugin/;

        / {
          compatible = "brcm,bcm2711";

          fragment@0 {
            target-path = "/soc/gpio@7e200000";
            __overlay__ {
              uart4_pins: uart4_pins {
                brcm,pins = <8 9>;
                brcm,function = <3>; /* alt4 = UART4 TXD/RXD */
                brcm,pull = <0 2>; /* TX no-pull, RX pull-up */
              };
            };
          };

          fragment@1 {
            target-path = "/soc/serial@7e201800"; /* UART4 */
            __overlay__ {
              pinctrl-names = "default";
              pinctrl-0 = <&uart4_pins>;
              status = "okay";
            };
          };
        };
      '';
    }
    {
      name = "i2s-audio-combined";
      dtsText = ''
        /dts-v1/;
        /plugin/;

        / {
          compatible = "brcm,bcm2711";

          fragment@0 {
            target = <&i2s>;
            __overlay__ {
              #sound-dai-cells = <0>;
              status = "okay";
            };
          };

          fragment@1 {
            target-path = "/";
            __overlay__ {
              max98357a_codec: max98357a {
                #sound-dai-cells = <0>;
                compatible = "maxim,max98357a";
                sdmode-gpios = <&gpio 4 0>;
                status = "okay";
              };
            };
          };

          fragment@2 {
            target-path = "/";
            __overlay__ {
              ics43432_codec: ics43432 {
                #sound-dai-cells = <0>;
                compatible = "invensense,ics43432";
                status = "okay";
              };
            };
          };

          fragment@3 {
            target-path = "/";
            __overlay__ {
              cogsworth_soundcard: cogsworth-sound {
                compatible = "simple-audio-card";
                simple-audio-card,name = "cogsworth-audio";
                status = "okay";

                simple-audio-card,dai-link@0 {
                  reg = <0>;
                  format = "i2s";
                  bitclock-master = <&p_cpu_dai>;
                  frame-master = <&p_cpu_dai>;

                  p_cpu_dai: cpu {
                    sound-dai = <&i2s>;
                  };

                  p_codec_dai: codec {
                    sound-dai = <&max98357a_codec>;
                  };
                };

                simple-audio-card,dai-link@1 {
                  reg = <1>;
                  format = "i2s";
                  bitclock-master = <&c_cpu_dai>;
                  frame-master = <&c_cpu_dai>;

                  c_cpu_dai: cpu {
                    sound-dai = <&i2s>;
                  };

                  c_codec_dai: codec {
                    sound-dai = <&ics43432_codec>;
                  };
                };
              };
            };
          };
        };
      '';
    }
  ];

  # Tier 3 Watchdog: Hardware watchdog timer
  # Ultimate failsafe - reboots system if kernel hangs
  # Raspberry Pi 4 has built-in bcm2835_wdt watchdog
  boot.kernelModules = [
    "bcm2835_wdt"
    # I2S audio modules for MAX98357A speaker and ICS-43434 microphone
    "snd_soc_bcm2835_i2s"
    "snd_soc_max98357a"
    "snd_soc_ics43432"
    "snd_soc_simple_card"
    "snd_soc_simple_card_utils"
  ];

  # Enable systemd hardware watchdog support
  # Systemd will feed the watchdog; if systemd hangs, RPi reboots
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s"; # Reboot if systemd doesn't ping within 30s
    RebootWatchdogSec = "2min"; # Reboot timeout if normal reboot fails
  };

  # Rotate framebuffer console to match physical display orientation (270° clockwise)
  boot.kernelParams = [
    "fbcon=rotate:3" # 3 = 270° clockwise (90° + 180°)
    "iomem=relaxed" # Required for GPIO memory access on NixOS
    "strict-devmem=0" # Allow pigpio to access GPIO memory
  ];

  # Use Raspberry Pi specific kernel for GPIO support
  boot.kernelPackages = pkgs.linuxPackages_rpi4;

  # Touchscreen calibration: identity matrix (no axis swap)
  # flutter-pi handles rotation→flutter coordinate mapping internally;
  # the matrix only corrects raw digitizer→screen alignment.
  services.udev.extraRules = ''
    SUBSYSTEM=="input", ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0"

    # Allow video group access to vchiq (for vcgencmd)
    SUBSYSTEM=="misc", KERNEL=="vchiq", MODE="0660", GROUP="video"
  '';

  # Seat management - flutter-pi uses libseat to access DRM devices
  services.seatd.enable = true;

  # Disable getty on tty1 - this kiosk uses flutter-pi on tty1 and SSH for management.
  # Masking both getty@tty1 and autovt@tty1 prevents systemd-getty-generator
  # from starting either during daemon-reload, which would conflict with flutter-pi
  # and cause deploy failures.
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  # Also prevent logind from auto-spawning gettys on other VTs.
  services.logind.settings.Login.NAutoVTs = 0;

  # Cogsworth application user
  users.users.cogsworth = {
    isSystemUser = true;
    group = "cogsworth";
    description = "Cogsworth kiosk application user";
    extraGroups = [
      "video"
      "i2c"
      "dialout"
      "gpio"
      "audio"
      "input"
      "render"
      "seat"
    ];
  };
  users.groups.cogsworth = { };

  # Add I2C access for kyle user (for development/debugging)
  users.users.kyle.extraGroups = [
    "gpio"
    "i2c"
    "dialout"
  ];

  # Enable lingering so systemd spawns user instance at boot
  # Required for home-manager user services on systems where kyle doesn't log in
  users.users.kyle.linger = true;

  # Allow cogsworth user to reboot system without password
  security.sudo.extraRules = [
    {
      users = [ "cogsworth" ];
      commands = [
        {
          command = "/run/current-system/sw/bin/systemctl reboot";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  # Cogsworth application service - runs Flutter kiosk via flutter-pi

  systemd.services.cogsworth = {
    description = "Cogsworth Flutter kiosk application";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "seatd.service"
    ];
    requires = [ "seatd.service" ];

    serviceConfig = {
      Type = "simple";
      User = "cogsworth";
      Group = "cogsworth";

      ExecStart = "${pkgs.flutter-pi}/bin/flutter-pi --release --rotation 270 /opt/cogsworth/";

      Environment = [
        "PATH=/run/current-system/sw/bin"
        "LD_LIBRARY_PATH=${pkgs.sqlite.out}/lib"
        "FLUTTER_PI=1"
      ];

      # flutter-pi needs tty1 for DRM master
      TTYPath = "/dev/tty1";
      StandardInput = "tty";
      StandardOutput = "journal";
      StandardError = "journal";

      # Tier 1 Watchdog: Enhanced restart policy
      Restart = "always";
      RestartSec = "5s";

      # Security hardening
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
        "AF_NETLINK"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      LockPersonality = true;
      SupplementaryGroups = [
        "render"
        "input"
      ];

      # Working directory for any file operations
      WorkingDirectory = "/var/lib/cogsworth";
      StateDirectory = "cogsworth";
      ReadWritePaths = [ "/run/cogsworth" ];
    };

    # Allow up to 10 restarts in 2 minutes before giving up
    startLimitBurst = 10;
    startLimitIntervalSec = 120;

    # Prevent permanent failure - allow watchdog to recover
    unitConfig = {
      StartLimitAction = "none";
    };
  };

  # Tier 2 Watchdog: Health check monitor
  # Detects when cogsworth is running but hung/unresponsive
  systemd.services.cogsworth-watchdog = {
    description = "Cogsworth health check watchdog";
    after = [ "cogsworth.service" ];

    serviceConfig = {
      Type = "oneshot";
      User = "root"; # Needs root to restart services
    };

    script = ''
      set -e

      STATE_DIR="/var/lib/cogsworth-watchdog"
      COGSWORTH_STATE_FILE="$STATE_DIR/failure_count"
      FAILURE_THRESHOLD=3  # Restart after 3 consecutive failures (90 seconds)

      # Ensure state directory exists
      mkdir -p "$STATE_DIR"

      # --- Check cogsworth HTTP health ---
      if [ -f "$COGSWORTH_STATE_FILE" ]; then
        FAILURES=$(cat "$COGSWORTH_STATE_FILE")
      else
        FAILURES=0
      fi

      if ${pkgs.curl}/bin/curl -sf --max-time 5 http://127.0.0.1:8080/debug/ping >/dev/null 2>&1; then
        # Health check passed - reset failure counter
        if [ "$FAILURES" -gt 0 ]; then
          echo "$(date): Cogsworth health check recovered (was $FAILURES failures)"
        fi
        echo "0" > "$COGSWORTH_STATE_FILE"
      else
        # Health check failed - increment counter
        FAILURES=$((FAILURES + 1))
        echo "$FAILURES" > "$COGSWORTH_STATE_FILE"
        echo "$(date): Cogsworth health check failed (attempt $FAILURES/$FAILURE_THRESHOLD)"

        # Restart cogsworth if threshold reached
        if [ "$FAILURES" -ge "$FAILURE_THRESHOLD" ]; then
          echo "$(date): WATCHDOG TRIGGERED - Restarting cogsworth.service"
          # Reset failed state first (handles restart limit scenario)
          systemctl reset-failed cogsworth.service || true
          systemctl restart cogsworth.service
          # Reset counter after restart
          echo "0" > "$COGSWORTH_STATE_FILE"
        fi
      fi
    '';
  };

  # Timer to run watchdog every 30 seconds
  systemd.timers.cogsworth-watchdog = {
    description = "Cogsworth health check watchdog timer";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnBootSec = "2min"; # Start 2 minutes after boot (let cogsworth stabilize)
      OnUnitActiveSec = "30s"; # Run every 30 seconds
      AccuracySec = "5s"; # Allow 5 second timing flexibility
    };
  };

  # Cogsworth reboot request handler
  # Monitors /run/cogsworth/reboot-request and triggers system reboot when present
  systemd.services.cogsworth-reboot = {
    description = "Cogsworth Reboot Handler";
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/rm -f /run/cogsworth/reboot-request";
      ExecStart = "${pkgs.systemd}/bin/systemctl reboot";
    };
  };

  systemd.paths.cogsworth-reboot = {
    description = "Watch for Cogsworth reboot requests";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExists = "/run/cogsworth/reboot-request";
      Unit = "cogsworth-reboot.service";
    };
  };

  # Cogsworth shutdown request handler
  # Monitors /run/cogsworth/shutdown-request and triggers system shutdown when present
  systemd.services.cogsworth-shutdown = {
    description = "Cogsworth Shutdown Handler";
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/rm -f /run/cogsworth/shutdown-request";
      ExecStart = "${pkgs.systemd}/bin/systemctl poweroff";
    };
  };

  systemd.paths.cogsworth-shutdown = {
    description = "Watch for Cogsworth shutdown requests";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathExists = "/run/cogsworth/shutdown-request";
      Unit = "cogsworth-shutdown.service";
    };
  };

  # Flutter assets and runtime data
  systemd.tmpfiles.rules = [
    "d /opt/cogsworth 0755 cogsworth cogsworth -"
    "d /run/cogsworth 0755 cogsworth cogsworth -"
  ];

  # Enable SSH for remote management
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
    };
    # Pin the host key (prevent NixOS from regenerating)
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };

  # mDNS disabled - using DNS/hosts entries instead
  services.avahi.enable = false;

  # Minimal system packages
  environment.systemPackages = with pkgs; [
    neovim
    htop
    sqlite # CLI database debugging
    libraspberrypi # Raspberry Pi userland tools (vcgencmd, etc.)
    alsa-utils # ALSA utilities (aplay, arecord, amixer, etc.)
    (writeShellScriptBin "edit-pi-config" ''
      set -euo pipefail

      FIRMWARE_DEV="/dev/disk/by-label/FIRMWARE"
      MOUNT_POINT="/mnt"
      CONFIG_FILE="$MOUNT_POINT/config.txt"

      if [[ ! -e "$FIRMWARE_DEV" ]]; then
        echo "Error: FIRMWARE partition not found at $FIRMWARE_DEV"
        exit 1
      fi

      if mountpoint -q "$MOUNT_POINT"; then
        echo "Error: $MOUNT_POINT is already mounted"
        exit 1
      fi

      cleanup() {
        if mountpoint -q "$MOUNT_POINT"; then
          echo "Unmounting $MOUNT_POINT..."
          sudo umount "$MOUNT_POINT"
        fi
      }
      trap cleanup EXIT

      echo "Mounting FIRMWARE partition..."
      sudo mount "$FIRMWARE_DEV" "$MOUNT_POINT"

      echo "Opening $CONFIG_FILE for editing..."
      sudo nvim "$CONFIG_FILE"

      echo "Done."
    '')
  ];

  # Monitoring stack - send metrics and logs to wolf
  systemFoundry.monitoringStack = {
    enable = true;

    nodeExporter.enable = true;

    vmagent = {
      enable = true;
      remoteWriteUrl = "https://metrics.apps.ondy.org/api/v1/write";
      bearerTokenFile = config.sops.secrets.monitoring_token_cogsworth.path;
      scrapeConfigs = [
        {
          job_name = "node";
          static_configs = [
            {
              targets = [ "127.0.0.1:9100" ];
              labels = {
                host = "cogsworth";
              };
            }
          ];
        }
        {
          job_name = "cogsworth";
          static_configs = [
            {
              targets = [ "127.0.0.1:8080" ];
              labels = {
                host = "cogsworth";
              };
            }
          ];
        }
      ];
    };

    promtail = {
      enable = true;
      lokiUrl = "https://loki.apps.ondy.org/loki/api/v1/push";
      bearerTokenFile = config.sops.secrets.monitoring_token_cogsworth.path;
      extraLabels = {
        host = "cogsworth";
      };
    };
  };

  # SD card wear reduction - minimize writes to extend card lifespan
  # Logs stored in RAM (acceptable since promtail forwards to Loki)
  systemFoundry.sdCardOptimization = {
    enable = true;
    tmpfsSize = "512M"; # /tmp in RAM
    logTmpfsSize = "256M"; # /var/log in RAM
    journalMaxSize = "50M"; # systemd journal max size in RAM
    enableZram = true; # Compressed swap in RAM for emergencies
    zramSize = 512; # 512MB zram swap
  };

  system.stateVersion = "25.05";
}
