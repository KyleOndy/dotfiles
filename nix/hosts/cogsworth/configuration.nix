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

  # Raspberry Pi 4 GPU configuration
  hardware.raspberry-pi."4" = {
    fkms-3d.enable = true; # V3D renderer for GPU acceleration
  };

  # Map touchscreen to HDMI output with 90° clockwise rotation calibration
  # Calibration matrix transforms touch coordinates to match rotated display
  # Matrix "0 -1 1 1 0 0" rotates touch input 90° CCW to match physical rotation
  services.udev.extraRules = ''
    SUBSYSTEM=="input", ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{WL_OUTPUT}="HDMI-A-1", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 -1 1 1 0 0"
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
        --start-fullscreen \
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
  };
  users.groups.cogsworth = { };

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

      # Restart policy
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

  # Mutable JAR location for development
  systemd.tmpfiles.rules = [ "d /opt/cogsworth 0755 cogsworth cogsworth -" ];

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
  ];

  system.stateVersion = "25.05";
}
