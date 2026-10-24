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

    compatAudio = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Keep the audio track Jellyfin plays by default from being DTS, on
        import and again in the sweep for whatever bypassed the hook.
        jellyfin-roku advertises dts whenever the Roku does, then fails
        DTS-HD MA and DTS:X before the first frame and never falls back to a
        transcode. An AC3 or EAC3 track in the same language is made the only
        default; without one, an AC3 copy of the DTS track is muxed in as the
        first and only default, keeping the DTS track behind it. A file still
        defaulting to DTS after the sweep is exported as
        media_audio_dts_default_file.

        Matroska only. Adding a track rewrites the whole file, so the import
        waits for a copy of it, and the sweep gains write access to `roots`.
        `audio-language-check --compat <file>...` does the same by hand, and
        with AUDIO_LANG_DRY_RUN=1 only prints what it would do.
      '';
    };
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    systemd.services.audio-language-sweep = {
      description = "Check library audio for a missing English track or a DTS default";

      # A run takes about 45 minutes. Restarting one mid-run makes the switch
      # wait for the oneshot to finish, past deploy-rs's activation timeout,
      # and the deploy rolls back. The next timer run picks up the change.
      restartIfChanged = false;

      path = [
        pkgs.audio-language-check
        pkgs.coreutils
      ];

      # The import hook runs as radarr and sonarr, outside `textfile`, so the
      # metric comes from a sweep rather than from the hook itself.
      serviceConfig = {
        Type = "oneshot";
        User = "audio-language";
        # A file the sweep rewrites takes this group, and has to stay in media
        # for the *arrs and the import hook to edit it. chgrp cannot fix it
        # afterwards: ~@privileged below filters the chown calls.
        Group = if cfg.compatAudio then "media" else "audio-language";
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

        ReadOnlyPaths = optionals (!cfg.compatAudio) cfg.roots;
        ReadWritePaths = [ (dirOf textfile) ] ++ optionals cfg.compatAudio cfg.roots;
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
        AUDIO_LANG_COMPAT = mkIf cfg.compatAudio "1";
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
      AUDIO_LANG_COMPAT = mkIf (cfg.compatAudio && config.services.radarr.enable) "1";
    };
    systemd.services.sonarr.environment = {
      AUDIO_LANG_ENFORCE = mkIf (cfg.enforceImports && config.services.sonarr.enable) "1";
      AUDIO_LANG_FIX = mkIf (cfg.promoteEnglishTrack && config.services.sonarr.enable) "1";
      AUDIO_LANG_COMPAT = mkIf (cfg.compatAudio && config.services.sonarr.enable) "1";
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
