{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.sabnzbd;
in
{
  options.systemFoundry.sabnzbd = {
    enable = mkEnableOption ''
      Batteries included wrapper for SABnzbd
    '';

    group = mkOption {
      type = types.str;
      default = "sabnzbd";
      description = "Group to run sabnzbd under";
    };

    domainName = mkOption {
      type = types.str;
      description = "Domain to server sabnzbd under";
    };

    downloadsDir = mkOption {
      type = types.str;
      default = "/mnt/scratch-big/downloads";
      description = ''
        The tree holding sabnzbd's download_dir and complete_dir, the only
        part of /mnt the service can see.
      '';
    };
  };

  config = mkIf cfg.enable {
    services = {
      # sabnzbd service
      sabnzbd = {
        enable = true;
        package = pkgs.sabnzbd;
        group = cfg.group;
        # sabnzbd.ini stays writable so the web UI owns every key nix does not
        # set. The keys nix does set, the module's own defaults included, are
        # merged back over the ini on each start, which reverts a web UI edit
        # to one of them at the next restart.
        configFile = null;
        allowConfigWrite = true;
        # SABnzbd reruns every conversion above the stored version on start,
        # and 5 resets each server's pipelining_requests to 1. nixpkgs defaults
        # this to 4, which would undo a pipelining change at every restart.
        # Glitter re-shows its new-skin notice while notified_new_skin < 2,
        # and nixpkgs' default renders as 1.
        settings.misc = {
          config_conversion_version = 5;
          notified_new_skin = 2;
        };
      };
    };

    # Files land 664 so the *arr services can import what sabnzbd downloads.
    # Group membership is the host's job: tiger sets `group = mediaGroup`,
    # which is already the process GID.
    systemd.services.sabnzbd = {
      serviceConfig = {
        UMask = "0002";

        # Everything under /mnt is hidden except the one tree sabnzbd.ini
        # points download_dir and complete_dir into. The state directory is
        # writable through the module's StateDirectory.
        TemporaryFileSystem = "/mnt:ro";
        BindPaths = [ cfg.downloadsDir ];

        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateUsers = true;
        ProtectClock = true;
        ProtectKernelLogs = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        RestrictSUIDSGID = true;
        RemoveIPC = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        # @chown for the module's preStart, which installs sabnzbd.ini with
        # -o/-g set to the service's own user and group.
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@debug"
          "~@mount"
          "@chown"
        ];
      };
      unitConfig.RequiresMountsFor = [ cfg.downloadsDir ];
    };

    # The queue and history are pickles sabnzbd loads on start, so nothing
    # but sabnzbd may write them.
    systemd.tmpfiles.rules = [
      "z /var/lib/${config.services.sabnzbd.stateDir}/admin 0700 ${config.services.sabnzbd.user} ${cfg.group} -"
    ];

    # A sabnzbd bump that adds a conversion would otherwise rerun it on every
    # start, silently.
    system.checks = [
      (pkgs.runCommand "sabnzbd-conversion-version" { } ''
        latest=$(sed -n 's/.*config_conversion_version() < \([0-9]*\):.*/\1/p' \
          ${config.services.sabnzbd.package}/sabnzbd/cfg.py | sort -n | tail -1)
        if [ "$latest" != ${toString config.services.sabnzbd.settings.misc.config_conversion_version} ]; then
          echo "sabnzbd ships config conversion $latest; bump config_conversion_version" >&2
          exit 1
        fi
        touch $out
      '')
    ];

    systemFoundry.caddyReverseProxy.sites."${cfg.domainName}" =
      mkIf config.systemFoundry.caddyReverseProxy.enable
        {
          enable = true;
          proxyPass = "http://127.0.0.1:8080";
        };
  };
}
