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
  };

  config = mkIf (parentCfg.enable && cfg.enable) {
    systemd.services.audio-language-sweep = {
      description = "Count library files whose audio has no English track";

      path = [
        pkgs.audio-language-check
        pkgs.coreutils
      ];

      # root, like the other textfile producers: the .prom directory is
      # root-owned 0755. The import hook cannot write here, which is why the
      # metric comes from a sweep rather than from the hook itself.
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        # ffprobe on every file plus whisper on the untagged ones; the run is
        # long and entirely IO and CPU the rest of the box wants more.
        Nice = 10;
        IOSchedulingClass = "idle";
      };

      environment = {
        AUDIO_LANG_TEXTFILE = textfile;
        AUDIO_LANG_ROOTS = concatStringsSep " " cfg.roots;
      };

      script = "audio-language-check --sweep";
    };

    # Guarded on the services existing: setting environment on an otherwise
    # undefined unit would generate one with no ExecStart.
    systemd.services.radarr.environment.AUDIO_LANG_ENFORCE = mkIf (
      cfg.enforceImports && config.services.radarr.enable
    ) "1";
    systemd.services.sonarr.environment.AUDIO_LANG_ENFORCE = mkIf (
      cfg.enforceImports && config.services.sonarr.enable
    ) "1";

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
