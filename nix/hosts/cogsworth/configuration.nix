{
  config,
  pkgs,
  lib,
  modulesPath,
  ...
}:
let
  # Build a proper derivation for the wake word models so the store path is
  # content-addressed and stable across repo commits. Using ./models directly
  # in a flake resolves to the entire flake source (-source suffix), whose hash
  # rotates on every commit and gets GC'd from the device.
  wakewordModels = pkgs.runCommand "cogsworth-wakeword-models" { } ''
    mkdir -p $out
    cp ${./models/100/hey_cogs.tflite} $out/hey_cogs.tflite
  '';
in
{
  imports = [ ];

  # Sops configuration - use pre-baked SSH host key for decryption
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # WiFi credentials from sops
  sops.secrets.home_wifi_ssid = { };
  sops.secrets.home_wifi_password = { };
  # vmagent (DynamicUser) and promtail (static user) both need to read this;
  # group-scoped via "monitoring-secrets" instead of world-readable (0444).
  sops.secrets.monitoring_password = {
    mode = "0440";
    group = "monitoring-secrets";
  };
  users.groups.monitoring-secrets = { };
  users.users.promtail.extraGroups = [ "monitoring-secrets" ];
  systemd.services.vmagent.serviceConfig.SupplementaryGroups = [ "monitoring-secrets" ];

  # Deepgram API key for speech-to-text
  sops.secrets.cogsworth_deepgram_api_key = {
    owner = "cogsworth";
  };

  # OpenRouter API key for LLM NLU (shopping item cleanup, intent classification)
  sops.secrets.cogsworth_openrouter_api_key = {
    owner = "cogsworth";
  };

  # Immich API key for photo screensaver
  sops.secrets.immich_api_key = {
    owner = "cogsworth";
  };

  # Location for weather widget (Open-Meteo API — no API key required)
  sops.secrets.weather_lat = {
    owner = "cogsworth";
  };
  sops.secrets.weather_lon = {
    owner = "cogsworth";
  };

  sops.templates."cogsworth-deepgram-env" = {
    owner = "cogsworth";
    content = ''
      COGSWORTH_DEEPGRAM_API_KEY=${config.sops.placeholder.cogsworth_deepgram_api_key}
    '';
  };

  sops.templates."cogsworth-immich-env" = {
    owner = "cogsworth";
    content = ''
      COGSWORTH_IMMICH_API_URL=https://immich.apps.ondy.org
      COGSWORTH_IMMICH_API_KEY=${config.sops.placeholder.immich_api_key}
    '';
  };

  sops.templates."cogsworth-weather-env" = {
    owner = "cogsworth";
    content = ''
      COGSWORTH_WEATHER_LAT=${config.sops.placeholder.weather_lat}
      COGSWORTH_WEATHER_LON=${config.sops.placeholder.weather_lon}
    '';
  };

  sops.templates."cogsworth-openrouter-env" = {
    owner = "cogsworth";
    content = ''
      cogsworth_openrouter_api_key=${config.sops.placeholder.cogsworth_openrouter_api_key}
    '';
  };

  # Twilio SMS reminders (two-way): inbound poller + confirmation replies.
  # Consumed by cogsworth.sms.config; the poller registers only when
  # account-sid + auth-token + number are all present in the environment.
  # Auth is a revocable API key (SID + secret); the account SID only scopes
  # the REST URL. The account auth token is not used by the poller.
  sops.secrets.cogsworth_sms_twilio_account_sid = {
    owner = "cogsworth";
  };
  sops.secrets.cogsworth_sms_twilio_api_key_sid = {
    owner = "cogsworth";
  };
  sops.secrets.cogsworth_sms_twilio_api_key_secret = {
    owner = "cogsworth";
  };
  sops.secrets.cogsworth_sms_twilio_number = {
    owner = "cogsworth";
  };
  sops.secrets.cogsworth_sms_allowed_numbers = {
    owner = "cogsworth";
  };

  sops.templates."cogsworth-sms-env" = {
    owner = "cogsworth";
    content = ''
      COGSWORTH_SMS_TWILIO_ACCOUNT_SID=${config.sops.placeholder.cogsworth_sms_twilio_account_sid}
      COGSWORTH_SMS_TWILIO_API_KEY_SID=${config.sops.placeholder.cogsworth_sms_twilio_api_key_sid}
      COGSWORTH_SMS_TWILIO_API_KEY_SECRET=${config.sops.placeholder.cogsworth_sms_twilio_api_key_secret}
      COGSWORTH_SMS_TWILIO_NUMBER=${config.sops.placeholder.cogsworth_sms_twilio_number}
      COGSWORTH_SMS_ALLOWED_NUMBERS=${config.sops.placeholder.cogsworth_sms_allowed_numbers}
    '';
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
    interfaces.wlan0.useDHCP = true;
  };

  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # SD card has no SMART support; smartd exits 17 with no devices found.
  services.smartd.enable = false;

  # SD image optimizations
  sdImage.compressImage = false; # Faster builds
  boot.supportedFilesystems.zfs = lib.mkForce false; # Not needed, speeds up build

  # Pi 5 kernel uses 16K pages (PAGE_SHIFT=14) with 47-bit VA space.
  # NixOS defaults to 33 (assumes 4K pages, 48-bit VA) because the
  # nixos-raspberrypi kernel doesn't expose config introspection.
  # Max = VA_BITS - PAGE_SHIFT - 3 = 47 - 14 - 3 = 30.
  boot.kernel.sysctl."vm.mmap_rnd_bits" = lib.mkForce 30;

  # Reduce SD card wear by disabling access time updates
  fileSystems."/" = lib.mkForce {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [
      "noatime"
      "nodiratime"
    ];
  };

  # sd-image-raspberrypi.nix defaults to noauto+x-systemd.automount, which
  # generates boot-firmware.mount via systemd-fstab-generator into
  # /run/systemd/generator/ instead of the toplevel's /etc/systemd/system/.
  # switch-to-configuration-ng (systemd 258) fails because it tries to open
  # the unit file from the toplevel path when restarting sysinit-reactivation.target.
  fileSystems."/boot/firmware".options = lib.mkOverride 0 [
    "noatime"
    "nofail"
  ];

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

  # config.txt settings (managed by nixos-raspberrypi; boot fundamentals are set by the module)
  hardware.raspberry-pi.config.all = {
    options.disable_splash = {
      enable = true;
      value = 1;
    };
    base-dt-params.i2c_arm = {
      enable = true;
      value = "on";
    };
  };

  # GPU drivers (creates /run/opengl-driver for mesa/GBM)
  hardware.graphics.enable = true;

  # I2C bus on GPIO pins 3 (SDA) and 5 (SCL), available at /dev/i2c-1
  hardware.i2c.enable = true;

  # Do NOT set hardware.deviceTree.filter on Pi 5: it breaks boot.
  # Bisected 2026-04-23 — setting any filter (even one matching bcm2712*)
  # causes brcmuart_init → bcm2712_pull_config_set SError during kernel
  # init. The nixos-raspberrypi + raspberrypi-firmware DTB install path
  # doesn't interact cleanly with this option under kernelboot.

  # Enable UART3 on GPIO8/9 (pins 24/21) for SEN0557 sensor.
  # On BCM2712 (Pi 5), &uart3 is the RP1 UART muxed to GPIO 8/9; &uart4 is GPIO 12/13.
  # The base DTB already defines uart3_pins via rp1_uart3_8_9 — just enable the UART.
  # Do NOT target &gpio here: that is the BCM2712 SoC GPIO controller, not the RP1
  # GPIO controller that drives the 40-pin header; applying pinctrl there causes a
  # bcm2712_pull_config_set SError on boot.
  # NOTE: every overlay entry sets `filter = "broadcom/"` so apply_overlays.py
  # only tries to apply it to DTBs under `dtbs/broadcom/` — skipping
  # `dtbs/overlays/overlay_map.dtb`, which has no compatible string and isn't
  # a real device tree (the script would otherwise FDT_ERR_BADOFFSET on it).
  # GPIO17 (pin 11) is the SEN0557 presence OUT. No DT overlay needed — a bare
  # pinctrl state has no effect without a consumer to request it. The cogsworth
  # app configures the pull-up via libgpiod (GPIO_V2_LINE_FLAG_BIAS_PULL_UP)
  # when it opens the line at startup.
  hardware.deviceTree.overlays = [
    {
      name = "uart3-enable";
      filter = "broadcom/";
      dtsText = ''
        /dts-v1/;
        /plugin/;

        / {
          compatible = "brcm,bcm2712";

          fragment@0 {
            target = <&uart3>;
            __overlay__ {
              status = "okay";
              pinctrl-0 = <&uart3_pins>;
            };
          };
        };
      '';
    }
    {
      name = "i2s-audio-combined";
      filter = "broadcom/";
      dtsText = ''
        /dts-v1/;
        /plugin/;

        / {
          compatible = "brcm,bcm2712";

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
  # bcm2835_wdt is built into the rpi5 kernel (not a loadable module); /dev/watchdog0 comes up
  # automatically. systemd.settings.Manager below feeds it.
  boot.kernelModules = [
    "v3d"
    "vc4"
    # I2S audio modules for MAX98357A speaker and ICS-43434 microphone
    # Pi 5 RP1 I2S uses Synopsys DesignWare IP (compatible = "snps,designware-i2s"),
    # not the Pi 4 bcm2835 I2S (compatible = "brcm,bcm2835-i2s").
    "designware_i2s"
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

  # ALSA audio chain for the MAX98357A amplifier.
  # speaker_dmix (dmix) -> hw:0,1 allows multiple processes to share the
  # hardware PCM simultaneously (the amp-keepalive silence stream and any
  # on-demand playback from the Go backend coexist without "device busy" errors).
  # softvol wraps the dmix and exposes a "SpeakerVol" mixer control (0-100%).
  environment.etc."asound.conf".text = ''
    pcm.speaker_dmix {
        type dmix
        ipc_key 1024
        slave {
            pcm "hw:0,1"
            rate 44100
            format S16_LE
            channels 2
        }
    }

    pcm.softvol {
        type softvol
        slave.pcm "speaker_dmix"
        control {
            name "SpeakerVol"
            card 0
        }
        min_dB -51.0
        max_dB  0.0
        resolution 101
    }

    pcm.alarmvol {
        type softvol
        slave.pcm "speaker_dmix"
        control {
            name "AlarmVol"
            card 0
        }
        min_dB -51.0
        max_dB  0.0
        resolution 101
    }

    pcm.alarm {
        type plug
        slave.pcm "alarmvol"
    }

    pcm.!default {
        type plug
        slave.pcm "softvol"
    }
  '';

  # CPU always at max frequency when awake (app dynamically switches to powersave on screen off)
  powerManagement.cpuFreqGovernor = "performance";

  # Rotate framebuffer console to match physical display orientation (90° clockwise)
  boot.kernelParams = [
    "fbcon=rotate:1" # 1 = 90° clockwise
    "iomem=relaxed" # Permissive MMIO access for GPIO and peripheral access
  ];

  # gpio group for /dev/gpiochip* (replaces nixos-hardware raspberry-pi-4 gpio module)
  users.groups.gpio = { };

  # Touchscreen calibration: identity matrix (no axis swap).
  # Sway handles display rotation; the matrix corrects raw digitizer→screen alignment.
  services.udev.extraRules = ''
    SUBSYSTEM=="input", ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0"

    # Allow video group access to vchiq (for vcgencmd)
    SUBSYSTEM=="misc", KERNEL=="vchiq", MODE="0660", GROUP="video"

    # Allow gpio group access to gpiochip devices (Pi 5 GPIO via RP1)
    KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"
    SUBSYSTEM=="gpio", GROUP="gpio", MODE="0660"

    # Disable WiFi power management - brcmfmac defaults to power_save on,
    # which sleeps the radio during idle and drops inbound SSH until the
    # client re-associates (e.g. a UniFi kick). Re-applies on every wlan0
    # appearance: boot, driver reload, reconnect.
    ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan0", RUN+="${pkgs.iw}/bin/iw dev wlan0 set power_save off"
  '';

  # Seat management - sway uses libseat to access DRM devices
  services.seatd.enable = true;

  # Disable getty on tty1 - the kiosk runs sway on tty1; getty would conflict.
  # Masking both getty@tty1 and autovt@tty1 prevents systemd-getty-generator
  # from starting either during daemon-reload.
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  # Also prevent logind from auto-spawning gettys on other VTs.
  services.logind.settings.Login.NAutoVTs = 0;

  # Cogsworth service (user/group/systemd service defined in nix/modules/nix_modules/cogsworth.nix)
  services.cogsworth = {
    enable = true;
    port = 8080;
    dataDir = "/var/lib/cogsworth";
    databasePath = "/var/lib/cogsworth/db/cogsworth.db";
    backup.enable = true;
    environmentFiles = [
      config.sops.templates."cogsworth-deepgram-env".path
      config.sops.templates."cogsworth-immich-env".path
      config.sops.templates."cogsworth-weather-env".path
      config.sops.templates."cogsworth-openrouter-env".path
      config.sops.templates."cogsworth-sms-env".path
    ];
  };

  # Voice: wyoming-openwakeword for wake word detection (loopback only)
  services.wyoming.openwakeword = {
    enable = true;
    uri = "tcp://127.0.0.1:10400";
    threshold = 0.5;
    triggerLevel = 1;
    customModelsDirectories = [ wakewordModels ];
  };

  systemd.services.cogsworth.environment = {
    COGSWORTH_VOICE_ENABLED = "true";
    COGSWORTH_VOICE_WYOMING_ADDR = "127.0.0.1:10400";
    COGSWORTH_VOICE_WAKEWORD_NAME = "hey_cogs";
    LOG_LEVEL = "DEBUG";
  };

  # Caddy reverse proxy: LAN HTTP access to cogsworth on port 80.
  # Using ":80" (not a hostname) disables Caddy's auto-HTTPS so no ACME/cert logic runs.
  # The Go app stays on :8080 with its tight sandbox; only Caddy is LAN-reachable.
  services.caddy = {
    enable = true;
    virtualHosts.":80".extraConfig = ''
      reverse_proxy 127.0.0.1:8080
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];

  # Add I2C access for kyle user (for development/debugging)
  users.users.kyle.extraGroups = [
    "gpio"
    "i2c"
    "dialout"
  ];

  # Enable lingering so systemd spawns user instance at boot
  # Required for home-manager user services on systems where kyle doesn't log in
  users.users.kyle.linger = true;

  # kyle: restart cogsworth services without password (for make deploy)
  security.sudo.extraRules = [
    {
      users = [ "cogsworth" ];
      commands = [
        {
          command = "/run/current-system/sw/bin/cogsworth-set-governor";
          options = [ "NOPASSWD" ];
        }
      ];
    }
    {
      users = [ "kyle" ];
      commands = [
        {
          command = "/run/current-system/sw/bin/systemctl restart cogsworth.service";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/systemctl daemon-reload";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/systemctl revert cogsworth.service";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/install -d /run/systemd/system/cogsworth.service.d";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/tee /run/systemd/system/cogsworth.service.d/dev-override.conf";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  # tmpfs mount for SQLite database (eliminates SD card I/O latency)
  fileSystems."/var/lib/cogsworth/db" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [
      "size=16M"
      "mode=0755"
      "uid=cogsworth"
      "gid=cogsworth"
      "noatime"
    ];
  };

  # Copy DB from persistent storage to tmpfs on boot
  systemd.services.cogsworth-db-restore = {
    description = "Restore Cogsworth DB from SD card to tmpfs";
    wantedBy = [ "multi-user.target" ];
    before = [ "cogsworth.service" ];
    after = [ "var-lib-cogsworth-db.mount" ];
    requires = [ "var-lib-cogsworth-db.mount" ];

    serviceConfig = {
      Type = "oneshot";
      User = "cogsworth";
      Group = "cogsworth";
      RemainAfterExit = true;
    };

    script = ''
      PERSISTENT="/var/lib/cogsworth/persistent"
      TMPFS="/var/lib/cogsworth/db"
      mkdir -p "$PERSISTENT"
      if [ -f "$PERSISTENT/cogsworth.db" ]; then
        cp "$PERSISTENT/cogsworth.db" "$TMPFS/cogsworth.db"
        if [ -f "$PERSISTENT/cogsworth.db-wal" ]; then
          cp "$PERSISTENT/cogsworth.db-wal" "$TMPFS/cogsworth.db-wal"
        fi
        if [ -f "$PERSISTENT/cogsworth.db-shm" ]; then
          cp "$PERSISTENT/cogsworth.db-shm" "$TMPFS/cogsworth.db-shm"
        fi
      fi
    '';
  };

  # Periodic snapshot: tmpfs DB -> SD card (every 5 minutes)
  systemd.services.cogsworth-db-snapshot = {
    description = "Snapshot Cogsworth DB from tmpfs to SD card";

    serviceConfig = {
      Type = "oneshot";
      User = "cogsworth";
      Group = "cogsworth";
    };

    script = ''
      PERSISTENT="/var/lib/cogsworth/persistent"
      TMPFS="/var/lib/cogsworth/db"
      mkdir -p "$PERSISTENT"
      if [ -f "$TMPFS/cogsworth.db" ]; then
        cp "$TMPFS/cogsworth.db" "$PERSISTENT/cogsworth.db.tmp"
        mv "$PERSISTENT/cogsworth.db.tmp" "$PERSISTENT/cogsworth.db"
      fi
    '';
  };

  systemd.timers.cogsworth-db-snapshot = {
    description = "Periodic Cogsworth DB snapshot timer";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5min";
    };
  };

  # Final DB snapshot on clean shutdown
  systemd.services.cogsworth-db-shutdown-snapshot = {
    description = "Final Cogsworth DB snapshot before shutdown";
    wantedBy = [ "multi-user.target" ];
    after = [ "cogsworth.service" ];
    before = [ "shutdown.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "cogsworth";
      Group = "cogsworth";
      ExecStop = "${pkgs.bash}/bin/bash -c 'cp /var/lib/cogsworth/db/cogsworth.db /var/lib/cogsworth/persistent/cogsworth.db 2>/dev/null || true'";
    };
  };

  # Keep the MAX98357A amplifier out of shutdown by holding the I2S PCM open
  # with a continuous silent stream. Without this, ALSA closes the interface
  # between sounds, the amp enters shutdown, and powers back on with an audible pop.
  systemd.services.cogsworth-amp-keepalive = {
    description = "MAX98357A amp keepalive (prevents power-on pop)";
    wantedBy = [ "multi-user.target" ];
    after = [ "sound.target" ];
    serviceConfig = {
      User = "cogsworth";
      Group = "cogsworth";
      ExecStart = "${pkgs.alsa-utils}/bin/aplay -D speaker_dmix -q -t raw -r 44100 -f S16_LE -c 2 /dev/zero";
      Restart = "always";
      RestartSec = "2s";
    };
  };

  # Set digipot (AD5241BRZ1M, 0x2C) to max resistance (minimum brightness) before
  # the app starts. The app takes over brightness control once running.
  systemd.services.cogsworth-brightness-init = {
    description = "Set display brightness digipot to safe minimum at boot";
    wantedBy = [ "multi-user.target" ];
    before = [ "cogsworth.service" ];
    after = [ "sysinit.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "cogsworth-brightness-init" ''
        ${pkgs.perl}/bin/perl -e '
          use POSIX qw(O_RDWR);
          use Fcntl;
          sysopen(my $fh, "/dev/i2c-1", O_RDWR) or die "open: $!";
          ioctl($fh, 0x0703, 0x2C) or die "ioctl: $!";
          syswrite($fh, chr(0x00).chr(0xFF)) or die "write: $!";
        '
      '';
    };
  };

  # Cogsworth kiosk — Wayland (sway-unwrapped) + Chromium.
  environment.etc."cogsworth/sway.config".text = ''
    # Panel is physically landscape but mounted portrait; rotate 90° CW.
    output HDMI-A-1 mode 1920x1080@60Hz transform 90 max_render_time 1

    # Rotate touch overlay to match display orientation (90° CW).
    # Matrix for 90° CW: [ 0 1 0 / -1 0 1 ]
    input type:touch calibration_matrix 0 1 0 -1 0 1

    # No visible window chrome.
    default_border none
    default_floating_border none
    hide_edge_borders none

    # Disable VT switching shortcuts so a stray Ctrl+Alt+Fx can't escape kiosk.
    bindsym --release Ctrl+Alt+F1 nop
    bindsym --release Ctrl+Alt+F2 nop
    bindsym --release Ctrl+Alt+F3 nop
    bindsym --release Ctrl+Alt+F4 nop
    bindsym --release Ctrl+Alt+F5 nop
    bindsym --release Ctrl+Alt+F6 nop
    bindsym --release Ctrl+Alt+F7 nop

    exec ${pkgs.chromium}/bin/chromium \
      --kiosk \
      --no-first-run \
      --no-default-browser-check \
      --noerrdialogs \
      --disable-infobars \
      --disable-session-crashed-bubble \
      --disable-pinch \
      --check-for-update-interval=31536000 \
      --ozone-platform=wayland \
      --ignore-gpu-blocklist \
      --enable-gpu-rasterization \
      --enable-zero-copy \
      "--enable-features=VaapiVideoDecoder,AcceleratedVideoDecoder" \
      "--disable-features=SkiaGraphite,UseChromeOSDirectVideoDecoder,OverscrollHistoryNavigation,TouchpadOverscrollHistoryNavigation,OptimizationGuideModelDownloading,OptimizationHints,OnDeviceModel" \
      "--js-flags=--max-old-space-size=256" \
      --process-per-site \
      --enable-logging=stderr \
      --user-data-dir=/run/cogsworth-kiosk/chromium \
      --remote-debugging-port=9222 \
      --remote-debugging-address=127.0.0.1 \
      --remote-allow-origins=* \
      http://localhost:8080
  '';

  # Chromium managed policy — disables DevTools entirely (no long-press
  # inspect, no keyboard shortcuts), suppresses browser-level prompts.
  environment.etc."chromium/policies/managed/cogsworth.json".text = builtins.toJSON {
    DeveloperToolsAvailability = 0; # 0 = Allowed (needed for --remote-debugging-port to function)
    BrowserSignin = 0; # disable sign-in UI
    BrowserAddPersonEnabled = false;
    BrowserGuestModeEnabled = false;
    IncognitoModeAvailability = 1; # disabled
    PasswordManagerEnabled = false;
    AutofillAddressEnabled = false;
    AutofillCreditCardEnabled = false;
    TranslateEnabled = false;
    PrintingEnabled = false;
    BookmarkBarEnabled = false;
    SearchSuggestEnabled = false;
  };

  systemd.services.cogsworth-kiosk = {
    description = "Cogsworth Kiosk (Sway + Chromium)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "cogsworth.service"
      "seatd.service"
      "network.target"
    ];
    requires = [
      "cogsworth.service"
      "seatd.service"
    ];

    # sway-unwrapped uses execlp("sh", ...) for exec config directives; sh
    # must be on PATH.
    path = [ pkgs.bash ];

    environment = {
      LIBSEAT_BACKEND = "seatd";
      # Allow Sway to start without physical keyboard/mouse attached.
      WLR_LIBINPUT_NO_DEVICES = "1";
      # System users have no PAM session, so no XDG_RUNTIME_DIR is set
      # automatically. wlroots requires it for the Wayland socket path.
      XDG_RUNTIME_DIR = "/run/cogsworth-kiosk";
      # The cogsworth system user's home is /var/empty (read-only). Chromium
      # and Mesa need a writable HOME for their caches/profile; point it at
      # the per-service runtime directory.
      HOME = "/run/cogsworth-kiosk";
    };

    serviceConfig = {
      Type = "simple";
      User = "cogsworth";
      Group = "cogsworth";
      TTYPath = "/dev/tty1";
      StandardInput = "tty";
      StandardOutput = "journal";
      StandardError = "journal";
      ExecStart = "${pkgs.sway-unwrapped}/bin/sway --config /etc/cogsworth/sway.config";
      Restart = "on-failure";
      RestartSec = "5s";
      RuntimeDirectory = "cogsworth-kiosk";
      RuntimeDirectoryMode = "0700";
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
      KIOSK_STATE_FILE="$STATE_DIR/kiosk_failure_count"
      KIOSK_ORIGIN_STATE_FILE="$STATE_DIR/kiosk_offorigin_count"
      FAILURE_THRESHOLD=3              # Backend: restart after 3 consecutive failures (90 seconds)
      KIOSK_FAILURE_THRESHOLD=5        # Kiosk: restart after 5 consecutive failures (150 seconds)
      KIOSK_ORIGIN_FAILURE_THRESHOLD=3 # Off-origin: restart after 3 consecutive failed snap-backs (90 seconds)
      KIOSK_GRACE_PERIOD_S=60          # Skip kiosk checks for 60s after a fresh start

      # Ensure state directory exists
      mkdir -p "$STATE_DIR"

      # --- Check cogsworth HTTP health ---
      if [ -f "$COGSWORTH_STATE_FILE" ]; then
        FAILURES=$(cat "$COGSWORTH_STATE_FILE")
      else
        FAILURES=0
      fi

      if ${pkgs.curl}/bin/curl -sf --max-time 5 http://127.0.0.1:8080/api/health >/dev/null 2>&1; then
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

      # --- Check kiosk renderer health ---
      if [ -f "$KIOSK_STATE_FILE" ]; then
        KIOSK_FAILURES=$(cat "$KIOSK_STATE_FILE")
      else
        KIOSK_FAILURES=0
      fi

      # Reset failure counter when the kiosk service has restarted since last check,
      # to avoid counting failures from a previous run against the new one.
      KIOSK_TIMESTAMP_FILE="$STATE_DIR/kiosk_start_timestamp"
      KIOSK_ACTIVE_MONOTONIC=$(systemctl show cogsworth-kiosk.service \
        -p ActiveEnterTimestampMonotonic --value 2>/dev/null || echo 0)
      LAST_KIOSK_TIMESTAMP=$(cat "$KIOSK_TIMESTAMP_FILE" 2>/dev/null || echo 0)
      if [ "$KIOSK_ACTIVE_MONOTONIC" != "$LAST_KIOSK_TIMESTAMP" ]; then
        echo "0" > "$KIOSK_STATE_FILE"
        echo "0" > "$KIOSK_ORIGIN_STATE_FILE"
        echo "$KIOSK_ACTIVE_MONOTONIC" > "$KIOSK_TIMESTAMP_FILE"
        KIOSK_FAILURES=0
      fi

      # Skip the CDP check during the grace period after a fresh kiosk start.
      # Pi 5 cold-starting Sway + Chromium can take >60s before CDP is ready.
      if [ "$KIOSK_ACTIVE_MONOTONIC" -gt 0 ]; then
        SYSTEM_UPTIME_US=$(${pkgs.gawk}/bin/awk '{printf "%d", $1 * 1000000}' /proc/uptime)
        KIOSK_AGE_S=$(( (SYSTEM_UPTIME_US - KIOSK_ACTIVE_MONOTONIC) / 1000000 ))
        if [ "$KIOSK_AGE_S" -lt "$KIOSK_GRACE_PERIOD_S" ]; then
          echo "$(date): Kiosk within grace period ($KIOSK_AGE_S s old), skipping CDP check"
          exit 0
        fi
      fi

      # Probe Chromium's CDP target list once; extract both the page's
      # WebSocket debugger URL and its current top-level URL out of it.
      CDP_TARGETS=$(${pkgs.curl}/bin/curl -sf --max-time 10 http://127.0.0.1:9222/json/list 2>/dev/null || true)
      KIOSK_WS=$(echo "$CDP_TARGETS" | grep -o '"webSocketDebuggerUrl": *"[^"]*"' | head -1 | cut -d'"' -f4)
      KIOSK_URL=$(echo "$CDP_TARGETS" | grep -o '"url": *"[^"]*"' | head -1 | cut -d'"' -f4)

      if [ -n "$KIOSK_WS" ]; then
        # Send a trivial Runtime.evaluate and check for a numeric response.
        RESULT=$(echo '{"id":1,"method":"Runtime.evaluate","params":{"expression":"1","returnByValue":true}}' \
          | timeout 5 ${pkgs.websocat}/bin/websocat --one-message -n "$KIOSK_WS" 2>/dev/null || true)
        if echo "$RESULT" | grep -q '"value":1'; then
          if [ "$KIOSK_FAILURES" -gt 0 ]; then
            echo "$(date): Kiosk renderer recovered (was $KIOSK_FAILURES failures)"
          fi
          echo "0" > "$KIOSK_STATE_FILE"
        else
          KIOSK_FAILURES=$((KIOSK_FAILURES + 1))
          echo "$KIOSK_FAILURES" > "$KIOSK_STATE_FILE"
          echo "$(date): Kiosk renderer unresponsive (attempt $KIOSK_FAILURES/$KIOSK_FAILURE_THRESHOLD)"
          if [ "$KIOSK_FAILURES" -ge "$KIOSK_FAILURE_THRESHOLD" ]; then
            echo "$(date): WATCHDOG TRIGGERED - Restarting cogsworth-kiosk.service"
            systemctl reset-failed cogsworth-kiosk.service || true
            systemctl restart cogsworth-kiosk.service
            echo "0" > "$KIOSK_STATE_FILE"
          fi
        fi

        # --- Origin check: the kiosk should always be on localhost ---
        # Defense in depth. The SPA never sets location.href off-origin
        # and the two external iframes use sandbox="allow-scripts
        # allow-same-origin" (no allow-top-navigation), but if the top
        # frame ever wanders, snap it back via CDP and only escalate to
        # a service restart if snap-back keeps failing.
        if [ -f "$KIOSK_ORIGIN_STATE_FILE" ]; then
          ORIGIN_FAILURES=$(cat "$KIOSK_ORIGIN_STATE_FILE")
        else
          ORIGIN_FAILURES=0
        fi

        case "$KIOSK_URL" in
          http://localhost*|http://127.0.0.1*)
            if [ "$ORIGIN_FAILURES" -gt 0 ]; then
              echo "$(date): Kiosk back on-origin (was $ORIGIN_FAILURES off-origin ticks)"
            fi
            echo "0" > "$KIOSK_ORIGIN_STATE_FILE"
            ;;
          *)
            ORIGIN_FAILURES=$((ORIGIN_FAILURES + 1))
            echo "$ORIGIN_FAILURES" > "$KIOSK_ORIGIN_STATE_FILE"
            echo "$(date): Kiosk off-origin: '$KIOSK_URL' (attempt $ORIGIN_FAILURES/$KIOSK_ORIGIN_FAILURE_THRESHOLD)"
            echo '{"id":2,"method":"Page.navigate","params":{"url":"http://localhost:8080"}}' \
              | timeout 5 ${pkgs.websocat}/bin/websocat --one-message -n "$KIOSK_WS" >/dev/null 2>&1 || true
            if [ "$ORIGIN_FAILURES" -ge "$KIOSK_ORIGIN_FAILURE_THRESHOLD" ]; then
              echo "$(date): WATCHDOG TRIGGERED - snap-back failed $ORIGIN_FAILURES times, restarting cogsworth-kiosk.service"
              systemctl reset-failed cogsworth-kiosk.service || true
              systemctl restart cogsworth-kiosk.service
              echo "0" > "$KIOSK_ORIGIN_STATE_FILE"
            fi
            ;;
        esac
      else
        # Browser process not answering CDP — count as a kiosk failure.
        KIOSK_FAILURES=$((KIOSK_FAILURES + 1))
        echo "$KIOSK_FAILURES" > "$KIOSK_STATE_FILE"
        echo "$(date): Kiosk CDP endpoint unavailable (attempt $KIOSK_FAILURES/$KIOSK_FAILURE_THRESHOLD)"
        if [ "$KIOSK_FAILURES" -ge "$KIOSK_FAILURE_THRESHOLD" ]; then
          echo "$(date): WATCHDOG TRIGGERED - Restarting cogsworth-kiosk.service"
          systemctl reset-failed cogsworth-kiosk.service || true
          systemctl restart cogsworth-kiosk.service
          echo "0" > "$KIOSK_STATE_FILE"
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

  # Daily reboot at 4am to clear accumulated state (Chromium leaks, tmpfs growth)
  systemd.services.cogsworth-daily-reboot = {
    enable = false;
    description = "Daily scheduled reboot";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl reboot";
    };
  };

  systemd.timers.cogsworth-daily-reboot = {
    enable = false;
    description = "Daily reboot timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
    };
  };

  # ── Google Photos display directory ─────────────────────────────────────────
  # Photos are downloaded directly by the cogsworth Go service via the Google
  # Photos Library API. No local processing pipeline is needed.
  systemd.tmpfiles.rules = [
    "d /var/lib/cogsworth/photos 0755 cogsworth cogsworth - -"
    "d /var/lib/cogsworth/photos/display 0755 cogsworth cogsworth - -"
    "d /var/lib/cogsworth/voice 0755 cogsworth cogsworth - -"
  ];

  # /var/lib/cogsworth/persistent is now created by the cogsworth module's tmpfiles rule.

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
    presence-debug # SEN0557 sensor debug tool
    libraspberrypi # Raspberry Pi userland tools (vcgencmd, etc.)
    alsa-utils # ALSA utilities (aplay, arecord, amixer, etc.)
    i2c-tools
    python3
    (writeShellScriptBin "cogsworth-set-governor" ''
      set -euo pipefail
      GOVERNOR="''${1:?Usage: cogsworth-set-governor <performance|powersave>}"
      case "$GOVERNOR" in
        performance|powersave|ondemand) ;;
        *) echo "Invalid governor: $GOVERNOR" >&2; exit 1 ;;
      esac
      for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "$GOVERNOR" > "$cpu"
      done
    '')
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

  # Monitoring stack - send metrics and logs to tiger
  systemFoundry.monitoringStack = {
    enable = true;

    nodeExporter.enable = true;

    vmagent = {
      enable = true;
      remoteWriteUrl = "https://metrics.tiger.infra.ondy.org/api/v1/write";
      basicAuth = {
        username = "monitoring";
        passwordFile = config.sops.secrets.monitoring_password.path;
      };
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
      lokiUrl = "https://loki.tiger.infra.ondy.org/loki/api/v1/push";
      basicAuth = {
        username = "monitoring";
        passwordFile = config.sops.secrets.monitoring_password.path;
      };
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
