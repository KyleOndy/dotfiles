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
        "size=512M"
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
        "size=256M"
      ];
    };

    # Optimize systemd journal for minimal disk writes
    services.journald.extraConfig = ''
      # Store journal in RAM only (volatile storage)
      Storage=volatile

      # Limit journal size in RAM
      RuntimeMaxUse=50M
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

    # Optional: zram compressed swap for emergency memory pressure
    # Uses RAM for swap with compression (no SD card writes)
    zramSwap = {
      enable = true;
      memoryPercent = 25; # Use up to 25% of RAM for compressed swap
      algorithm = "zstd"; # Fast compression
      priority = 10; # Higher priority than disk swap
    };

    # Reduce systemd unit logging verbosity
    # Limits what gets written to journal
    systemd.settings.Manager = {
      LogLevel = "notice";
      DumpCore = false;
    };

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
  };
}
