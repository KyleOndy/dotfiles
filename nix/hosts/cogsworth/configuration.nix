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

  # Disable rainbow splash and enable UART4 for SEN0557 sensor
  sdImage.populateFirmwareCommands = lib.mkAfter ''
    chmod +w ./firmware/config.txt
    echo "disable_splash=1" >> ./firmware/config.txt
    echo "dtoverlay=uart4" >> ./firmware/config.txt
  '';

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
  ];

  # Tier 3 Watchdog: Hardware watchdog timer
  # Ultimate failsafe - reboots system if kernel hangs
  # Raspberry Pi 4 has built-in bcm2835_wdt watchdog
  boot.kernelModules = [ "bcm2835_wdt" ];

  # Enable systemd hardware watchdog support
  # Systemd will feed the watchdog; if systemd hangs, RPi reboots
  systemd.watchdog = {
    runtimeTime = "30s"; # Reboot if systemd doesn't ping within 30s
    rebootTime = "2min"; # Reboot timeout if normal reboot fails
  };

  # Rotate framebuffer console to match physical display orientation (270° clockwise)
  boot.kernelParams = [
    "fbcon=rotate:3" # 3 = 270° clockwise (90° + 180°)
  ];

  # Map touchscreen to HDMI output with 90° clockwise rotation calibration
  # Calibration matrix transforms touch coordinates to match rotated display
  # Matrix "0 -1 1 1 0 0" rotates touch input 90° CCW to match physical rotation
  services.udev.extraRules = ''
    SUBSYSTEM=="input", ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{WL_OUTPUT}="HDMI-A-1", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 -1 1 1 0 0"

    # Allow video group access to vchiq (for vcgencmd)
    SUBSYSTEM=="vchiq", MODE="0660", GROUP="video"
  '';

  # Cage kiosk configuration
  services.cage = {
    enable = true;
    user = "kiosk";
    # Wrapper script applies 90° rotation via wlr-randr before launching chromium
    # This runs inside the cage Wayland session, so it has proper display access
    program = pkgs.writeShellScript "kiosk-chromium" ''
      ${pkgs.wlr-randr}/bin/wlr-randr --output HDMI-A-1 --transform 90

      # Use fresh profile directory each boot to avoid session restore prompts
      CHROME_DATA_DIR="/tmp/chromium-kiosk-$$"
      mkdir -p "$CHROME_DATA_DIR"

      exec ${pkgs.chromium}/bin/chromium \
        --kiosk \
        --noerrdialogs \
        --disable-infobars \
        --no-first-run \
        --disable-session-crashed-bubble \
        --disable-restore-session-state \
        --user-data-dir="$CHROME_DATA_DIR" \
        --ozone-platform=wayland \
        --enable-features=UseOzonePlatform \
        --enable-virtual-keyboard \
        --remote-debugging-port=9222 \
        http://127.0.0.1:8080
    '';
    extraArguments = [
      "-s" # Disable VT switching
    ];
  };

  # Kiosk user (separate from kyle for security isolation)
  users.users.kiosk = {
    isNormalUser = true;
    group = "kiosk";
    extraGroups = [ "video" ]; # Required for GPU/DRI access
  };
  users.groups.kiosk = { };

  # Cogsworth application user (system user for running Java uberjar)
  users.users.cogsworth = {
    isSystemUser = true;
    group = "cogsworth";
    description = "Cogsworth application service user";
    extraGroups = [
      "video"
      "i2c"
      "dialout"
      "gpio"
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

  # Chromium policies for kiosk hardening
  programs.chromium = {
    enable = true;
    extraOpts = {
      BrowserSignin = 0;
      SyncDisabled = true;
      PasswordManagerEnabled = false;
      SpellcheckEnabled = false;
      TranslateEnabled = false;
    };
  };

  # Ensure cage waits for cogsworth app to be ready
  systemd.services."cage-tty1" = {
    after = [
      "network-online.target"
      "cogsworth-ready.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "cogsworth-ready.service" ];

    # Auto-restart on failure (e.g., after deploy-rs, crashes, etc.)
    serviceConfig = {
      Restart = "always";
      RestartSec = "5s";
    };

    # Allow up to 10 restarts in 2 minutes before giving up
    # These go in [Unit] section, not [Service]
    startLimitBurst = 10;
    startLimitIntervalSec = 120;

    # Prevent permanent failure - allow watchdog to recover
    unitConfig = {
      StartLimitAction = "none";
    };
  };

  # Cogsworth application service - runs the Java uberjar
  systemd.services.cogsworth = {
    description = "Cogsworth display application";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      User = "cogsworth";
      Group = "cogsworth";

      # JRE execution with JVM tuning for Raspberry Pi
      ExecStart = ''
        ${pkgs.jre_headless}/bin/java \
          -Xms64m \
          -Xmx256m \
          -XX:+UseG1GC \
          -XX:MaxGCPauseMillis=100 \
          -Dserver.port=8080 \
          -jar /opt/cogsworth/cogsworth.jar
      '';

      # Tier 1 Watchdog: Enhanced restart policy
      # Aggressively restart on any failure type
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
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      LockPersonality = true;

      # Working directory for any file operations
      WorkingDirectory = "/var/lib/cogsworth";
      StateDirectory = "cogsworth";
      ReadWritePaths = [ "/run/cogsworth" ];
    };

    # Allow up to 10 restarts in 2 minutes before giving up
    # Default is 5 restarts in 10 seconds which is too restrictive
    # These go in [Unit] section, not [Service]
    startLimitBurst = 10;
    startLimitIntervalSec = 120;

    # If service hits restart limit, reset the counter after 5 minutes
    # This prevents permanent failure from transient issues
    unitConfig = {
      StartLimitAction = "none";
    };
  };

  # Cogsworth health check service - waits for /health endpoint
  systemd.services.cogsworth-ready = {
    description = "Wait for Cogsworth application to be ready";
    after = [ "cogsworth.service" ];
    requires = [ "cogsworth.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "90s";
    };

    script = ''
      set -e

      echo "Waiting for Cogsworth to be ready (max 60 seconds)..."

      # Poll root endpoint every 2 seconds, max 30 attempts (60 seconds)
      for i in $(seq 1 30); do
        if ${pkgs.curl}/bin/curl -sf http://127.0.0.1:8080/ >/dev/null 2>&1; then
          echo "Cogsworth is ready (attempt $i)"
          exit 0
        fi
        echo "Attempt $i/30 - waiting..."
        sleep 2
      done

      echo "ERROR: Cogsworth did not become ready within 60 seconds"
      exit 1
    '';
  };

  # Tier 2 Watchdog: Health check monitor
  # Detects when services are running but hung/unresponsive or failed
  systemd.services.cogsworth-watchdog = {
    description = "Cogsworth and Cage health check watchdog";
    after = [
      "cogsworth.service"
      "cage-tty1.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      User = "root"; # Needs root to restart services
    };

    script = ''
      set -e

      STATE_DIR="/var/lib/cogsworth-watchdog"
      COGSWORTH_STATE_FILE="$STATE_DIR/failure_count"
      CAGE_STATE_FILE="$STATE_DIR/cage_failure_count"
      FAILURE_THRESHOLD=3  # Restart after 3 consecutive failures (90 seconds)

      # Ensure state directory exists
      mkdir -p "$STATE_DIR"

      # --- Check cogsworth HTTP health ---
      if [ -f "$COGSWORTH_STATE_FILE" ]; then
        FAILURES=$(cat "$COGSWORTH_STATE_FILE")
      else
        FAILURES=0
      fi

      if ${pkgs.curl}/bin/curl -sf --max-time 5 http://127.0.0.1:8080/ >/dev/null 2>&1; then
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

      # --- Check cage-tty1 systemd state ---
      if [ -f "$CAGE_STATE_FILE" ]; then
        CAGE_FAILURES=$(cat "$CAGE_STATE_FILE")
      else
        CAGE_FAILURES=0
      fi

      if systemctl is-active --quiet cage-tty1.service; then
        # Service is running - reset failure counter
        if [ "$CAGE_FAILURES" -gt 0 ]; then
          echo "$(date): cage-tty1 recovered (was $CAGE_FAILURES failures)"
        fi
        echo "0" > "$CAGE_STATE_FILE"
      else
        # Service is not active - increment counter
        CAGE_FAILURES=$((CAGE_FAILURES + 1))
        echo "$CAGE_FAILURES" > "$CAGE_STATE_FILE"
        echo "$(date): cage-tty1 not active (attempt $CAGE_FAILURES/$FAILURE_THRESHOLD)"

        # Restart cage if threshold reached
        if [ "$CAGE_FAILURES" -ge "$FAILURE_THRESHOLD" ]; then
          echo "$(date): WATCHDOG TRIGGERED - Restarting cage-tty1.service"
          # Reset failed state first (handles restart limit scenario)
          systemctl reset-failed cage-tty1.service || true
          systemctl restart cage-tty1.service
          # Reset counter after restart
          echo "0" > "$CAGE_STATE_FILE"
        fi
      fi
    '';
  };

  # Timer to run watchdog every 30 seconds
  systemd.timers.cogsworth-watchdog = {
    description = "Cogsworth and Cage health check watchdog timer";
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

  # Mutable JAR location for development
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
    wlr-randr # For runtime display rotation
    libraspberrypi # Raspberry Pi userland tools (vcgencmd, etc.)
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
  # Chromium profile and temp files use tmpfs instead of SD card
  systemFoundry.sdCardOptimization = {
    enable = true;
    tmpfsSize = "512M"; # /tmp in RAM (chromium profile, etc.)
    logTmpfsSize = "256M"; # /var/log in RAM
    journalMaxSize = "50M"; # systemd journal max size in RAM
    enableZram = true; # Compressed swap in RAM for emergencies
    zramSize = 512; # 512MB zram swap
  };

  system.stateVersion = "25.05";
}
