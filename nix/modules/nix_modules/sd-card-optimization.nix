{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.sdCardOptimization;
in
{
  options.systemFoundry.sdCardOptimization = {
    enable = mkEnableOption "SD card wear reduction optimizations";

    tmpfsSize = mkOption {
      type = types.str;
      default = "512M";
      description = "Size limit for /tmp tmpfs mount";
    };

    logTmpfsSize = mkOption {
      type = types.str;
      default = "256M";
      description = "Size limit for /var/log tmpfs mount";
    };

    journalMaxSize = mkOption {
      type = types.str;
      default = "50M";
      description = "Maximum size of systemd journal (runtime storage)";
    };

    enableZram = mkOption {
      type = types.bool;
      default = true;
      description = "Enable zram compressed swap for emergency memory pressure";
    };

    zramSize = mkOption {
      type = types.int;
      default = 512;
      description = "Size of zram swap in MB";
    };
  };

  config = mkIf cfg.enable {
    # Mount /tmp in RAM with size limit
    # Chromium profile and other temp files go here instead of SD card
    fileSystems."/tmp" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [
        "mode=1777"
        "nosuid"
        "nodev"
        "size=${cfg.tmpfsSize}"
      ];
    };

    # Mount /var/log in RAM
    # All logs kept in memory - acceptable since promtail sends to Loki
    fileSystems."/var/log" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [
        "mode=0755"
        "nosuid"
        "nodev"
        "noexec"
        "size=${cfg.logTmpfsSize}"
      ];
    };

    # Optimize systemd journal for minimal disk writes
    services.journald.extraConfig = ''
      # Store journal in RAM only (volatile storage)
      Storage=volatile

      # Limit journal size in RAM
      RuntimeMaxUse=${cfg.journalMaxSize}
      RuntimeMaxFileSize=10M

      # Keep only recent logs
      MaxRetentionSec=1h
      MaxFileSec=5min

      # Reduce write frequency - batch writes
      SyncIntervalSec=60s
      RateLimitIntervalSec=30s
      RateLimitBurst=10000

      # Forward to syslog/kmsg at lower priority to reduce duplicates
      ForwardToSyslog=no
      ForwardToKMsg=no
      ForwardToConsole=no
    '';

    # Enable noatime on root filesystem to avoid updating access times
    # Note: For SD card systems, this should be set in the host configuration
    # since the root filesystem is defined by the SD image builder
    # Example for host config:
    #   fileSystems."/" = lib.mkForce {
    #     device = "/dev/disk/by-label/NIXOS_SD";
    #     fsType = "ext4";
    #     options = [ "noatime" "nodiratime" ];
    #   };

    # Optional: zram compressed swap for emergency memory pressure
    # Uses RAM for swap with compression (no SD card writes)
    zramSwap = mkIf cfg.enableZram {
      enable = true;
      memoryPercent = 25; # Use up to 25% of RAM for compressed swap
      algorithm = "zstd"; # Fast compression
      priority = 10; # Higher priority than disk swap
    };

    # Reduce systemd unit logging verbosity
    # Limits what gets written to journal
    systemd.extraConfig = ''
      # Reduce log verbosity for systemd itself
      LogLevel=notice
      DumpCore=no
    '';

    # Disable coredumps (they write to disk)
    systemd.coredump.enable = false;

    # Optimize vm.dirty ratios for less frequent disk writes
    # Batch more data before flushing to disk
    boot.kernel.sysctl = {
      # Percentage of memory that can be filled with dirty pages before flush
      "vm.dirty_ratio" = 80;
      "vm.dirty_background_ratio" = 50;

      # Time before dirty pages are written (centiseconds)
      "vm.dirty_expire_centisecs" = 6000; # 60 seconds
      "vm.dirty_writeback_centisecs" = 3000; # 30 seconds

      # Reduce swappiness (prefer using RAM over swap)
      "vm.swappiness" = 10;
    };

    # Log rotation is unnecessary with tmpfs logs, but configure just in case
    services.logrotate = {
      enable = false; # Not needed for tmpfs logs
    };

    # Periodic warning about tmpfs logs (printed to console on boot)
    systemd.services.sd-card-optimization-notice = {
      description = "SD card optimization notice";
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        echo "========================================" | ${pkgs.systemd}/bin/systemd-cat
        echo "SD CARD OPTIMIZATION ENABLED" | ${pkgs.systemd}/bin/systemd-cat
        echo "Logs are stored in RAM (tmpfs)" | ${pkgs.systemd}/bin/systemd-cat
        echo "Logs will be lost on power failure!" | ${pkgs.systemd}/bin/systemd-cat
        echo "All logs forwarded to Loki for persistence" | ${pkgs.systemd}/bin/systemd-cat
        echo "========================================" | ${pkgs.systemd}/bin/systemd-cat
      '';
    };
  };
}
