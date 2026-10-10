{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  parentCfg = config.systemFoundry.monitoringStack;
  cfg = config.systemFoundry.monitoringStack.audioLanguage;

  textfile = "/var/lib/prometheus-node-exporter-text-files/audio_language.prom";
in
{
  options.systemFoundry.monitoringStack.audioLanguage = {
    enable = mkEnableOption "sweep the library for files with no English audio";

    roots = mkOption {
      type = types.listOf types.str;
      default = [
        "/mnt/media/tv"
        "/mnt/media/movies"
      ];
      description = ''
        Directories to walk. Each becomes the `library` label, taken from its
        basename.
      '';
    };

    schedule = mkOption {
      type = types.str;
      default = "daily";
      description = "OnCalendar expression for the sweep";
    };

    enforceImports = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Let the import hook fail a download whose audio carries no English
        track, instead of only logging the verdict. Radarr and Sonarr run the
        hook themselves, so the switch reaches it through their own service
        environment rather than through the sweep unit.

        A failed import is blocklisted, and `autoRedownloadFailed` then sends
        the *arr after the next release, which is what makes a bad grab
        correct itself instead of waiting for the sweep to notice.
      '';
    };

    promoteEnglishTrack = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Write whisper's verdicts into the file on import: make the English
        track the default one where the file has English but plays something
        else, and relabel a track whose tag is missing or names another
        language for English audio. A multi-language release commonly ships
        sixteen tracks with the default flag set on none of them, in an order
        that puts English second, so a player picks the first and the episode
        comes out in Swedish.

        Matroska only. mkvpropedit rewrites the flag in the header, so the
        file is not re-encoded and its size does not change; mp4 has no
        header-level equivalent and would need a full remux, so it is left
        alone.
      '';
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    systemd.services.audio-language-sweep = {
      description = "Count library files whose audio has no English track";

      path = [
        pkgs.audio-language-check
        pkgs.coreutils
      ];

      # The import hook runs as radarr and sonarr, outside `textfile`, so the
      # metric comes from a sweep rather than from the hook itself.
      serviceConfig = {
        Type = "oneshot";
        User = "audio-language";
        Group = "audio-language";
        SupplementaryGroups = [
          "media"
          "textfile"
        ];
        # ffprobe on every file plus whisper on the untagged ones; the run is
        # long and entirely IO and CPU the rest of the box wants more.
        Nice = 10;
        IOSchedulingClass = "idle";

        # The sweep asks Radarr and Sonarr for each title's original
        # language, with the key from their own config.xml, which only they
        # can read.
        LoadCredential =
          optional config.services.radarr.enable "radarr-config:${config.services.radarr.dataDir}/config.xml"
          ++ optional config.services.sonarr.enable "sonarr-config:${config.services.sonarr.dataDir}/config.xml";

        ReadOnlyPaths = cfg.roots;
        ReadWritePaths = [ (dirOf textfile) ];
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateIPC = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        # Loopback only, for the Radarr and Sonarr APIs. PrivateNetwork would
        # cut those off, and an empty language index counts every
        # foreign-language title as a file missing English audio.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
      };

      environment = {
        AUDIO_LANG_TEXTFILE = textfile;
        AUDIO_LANG_ROOTS = concatStringsSep " " cfg.roots;
        RADARR_CONFIG = "%d/radarr-config";
        SONARR_CONFIG = "%d/sonarr-config";
      };

      script = "audio-language-check --sweep";
    };

    users.users.audio-language = {
      isSystemUser = true;
      group = "audio-language";
    };
    users.groups.audio-language = { };

    # The directory is sticky, so a file any other user owns blocks the
    # rename that replaces it.
    systemd.tmpfiles.rules = [ "z ${textfile} 0644 audio-language textfile -" ];

    # Guarded on the services existing: setting environment on an otherwise
    # undefined unit would generate one with no ExecStart.
    systemd.services.radarr.environment = {
      AUDIO_LANG_ENFORCE = mkIf (cfg.enforceImports && config.services.radarr.enable) "1";
      AUDIO_LANG_FIX = mkIf (cfg.promoteEnglishTrack && config.services.radarr.enable) "1";
    };
    systemd.services.sonarr.environment = {
      AUDIO_LANG_ENFORCE = mkIf (cfg.enforceImports && config.services.sonarr.enable) "1";
      AUDIO_LANG_FIX = mkIf (cfg.promoteEnglishTrack && config.services.sonarr.enable) "1";
    };

    systemd.timers.audio-language-sweep = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };
  };
}
