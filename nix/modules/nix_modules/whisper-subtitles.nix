{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.whisperSubtitles;

  whisperCpp = pkgs.whisper-cpp.override { vulkanSupport = true; };

  # Build find expression for configured extensions (case-insensitive)
  findExpr = concatStringsSep " -o " (map (ext: ''-iname "*.${ext}"'') cfg.extensions);

  whisperScript = pkgs.writeShellScript "whisper-subtitle-generate" ''
    set -euo pipefail

    PATH="${
      lib.makeBinPath [
        whisperCpp
        pkgs.ffmpeg-headless
        pkgs.findutils
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.wget
      ]
    }"

    MODEL_DIR="${cfg.modelDir}"
    MODEL_NAME="${cfg.model}"
    MODEL_PATH="$MODEL_DIR/ggml-''${MODEL_NAME}.bin"

    # Download model if not present
    if [[ ! -f "$MODEL_PATH" ]]; then
      echo "Downloading whisper model: $MODEL_NAME"
      mkdir -p "$MODEL_DIR"
      whisper-cpp-download-ggml-model "$MODEL_NAME" "$MODEL_DIR" 2>&1 | tail -1
      echo "Model downloaded: $MODEL_PATH"
    fi

    process_file() {
      local video="$1"
      local dir base ext srt_path tmpdir

      dir=$(dirname "$video")
      base=$(basename "$video")
      ext="''${base##*.}"
      base="''${base%.*}"
      srt_path="$dir/$base.en.whisper.srt"

      # Skip if srt already exists
      if [[ -f "$srt_path" ]]; then
        return 0
      fi

      echo "Processing: $video"

      tmpdir=$(mktemp -d)
      trap 'rm -rf "$tmpdir"' RETURN

      # Extract audio to 16kHz mono WAV
      if ! ffmpeg -nostdin -v error -i "$video" -ar 16000 -ac 1 -c:a pcm_s16le "$tmpdir/audio.wav"; then
        echo "  ERROR: failed to extract audio from $video" >&2
        return 1
      fi

      # Run whisper-cpp (suppress per-segment output to keep logs clean)
      if ! whisper-cli -m "$MODEL_PATH" -osrt -of "$tmpdir/output" -l en --no-prints "$tmpdir/audio.wav" >/dev/null 2>&1; then
        echo "  ERROR: whisper transcription failed for $video" >&2
        return 1
      fi

      if [[ ! -s "$tmpdir/output.srt" ]]; then
        echo "  WARNING: whisper produced empty output for $video" >&2
        return 1
      fi

      # Preserve ownership of source video
      local orig_owner
      orig_owner=$(stat -c "%u:%g" "$video")
      chown "$orig_owner" "$tmpdir/output.srt" 2>/dev/null || true

      mv "$tmpdir/output.srt" "$srt_path"
      trap - RETURN
      rm -rf "$tmpdir"

      echo "  -> $(basename "$srt_path")"
    }

    # Main: file or directory mode
    if [[ $# -lt 1 ]]; then
      echo "Usage: whisper-subtitle-generate <file-or-directory> [...]" >&2
      exit 1
    fi

    for TARGET in "$@"; do
      if [[ -f "$TARGET" ]]; then
        process_file "$TARGET" || echo "  skipping: $TARGET" >&2
      elif [[ -d "$TARGET" ]]; then
        # Find video files, sort newest-first by mtime
        while IFS= read -r video; do
          process_file "$video" || echo "  skipping: $video" >&2
        done < <(find "$TARGET" -type f \( ${findExpr} \) -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
      else
        echo "Error: $TARGET is not a file or directory" >&2
      fi
    done
  '';

  # Wrapper that passes all mediaPaths to the script
  batchExec = pkgs.writeShellScript "whisper-subtitles-batch" ''
    set -euo pipefail
    exec ${pkgs.util-linux}/bin/flock /run/whisper-subtitles/lock \
      ${whisperScript} ${concatStringsSep " " (map (p: ''"${p}"'') cfg.mediaPaths)}
  '';

  extensionCase = concatStringsSep "|" cfg.extensions;
in
{
  options.systemFoundry.whisperSubtitles = {
    enable = mkEnableOption "whisper subtitle generation via whisper-cpp with Vulkan GPU";

    mediaPaths = mkOption {
      type = types.listOf types.path;
      default = [
        "/mnt/storage/media/tv"
        "/mnt/storage/media/movies"
      ];
      description = "Directories to scan recursively for video files";
    };

    mountPoint = mkOption {
      type = types.path;
      default = "/mnt/storage";
      description = "Mount point that must be available before the service starts";
    };

    schedule = mkOption {
      type = types.str;
      default = "*-*-* 03:00:00";
      description = "Systemd timer schedule (OnCalendar format)";
    };

    model = mkOption {
      type = types.str;
      default = "large-v3";
      description = "Whisper ggml model name (downloaded from huggingface on first run)";
    };

    modelDir = mkOption {
      type = types.path;
      default = "/var/lib/whisper-subtitles";
      description = "Directory to store downloaded ggml model files";
    };

    user = mkOption {
      type = types.str;
      default = "whisper";
      description = "User to run whisper as";
    };

    group = mkOption {
      type = types.str;
      default = "media";
      description = "Group to run whisper as";
    };

    extensions = mkOption {
      type = types.listOf types.str;
      default = [
        "mkv"
        "mp4"
        "avi"
      ];
      description = "Video file extensions to process (case-insensitive)";
    };
  };

  config = mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      extraGroups = [
        "render"
        "video"
      ];
    };

    systemd.services.whisper-subtitles = {
      description = "Generate .en.whisper.srt subtitles via whisper-cpp (Vulkan GPU)";
      restartIfChanged = false;
      after = [
        "network.target"
        "remote-fs.target"
      ];
      unitConfig = {
        ConditionPathIsMountPoint = cfg.mountPoint;
      };

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        SupplementaryGroups = [
          "render"
          "video"
        ];
        ExecStart = batchExec;
        Nice = 19;
        IOSchedulingClass = "idle";
        TimeoutStartSec = "48h";
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = cfg.mediaPaths ++ [ cfg.modelDir ];
        StateDirectory = "whisper-subtitles";
        RuntimeDirectory = "whisper-subtitles";
      };
    };

    systemd.timers.whisper-subtitles = {
      description = "Timer for whisper subtitle generation";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

    # CLI wrapper for manual runs (no flock)
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "whisper-subtitle-generate" ''
        exec ${whisperScript} "$@"
      '')
    ];

    # Sonarr/Radarr post-import hook
    environment.etc."scripts/whisper-subtitle-notify.sh" = {
      mode = "0755";
      text = ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail

        FILE_PATH="''${sonarr_episodefile_path:-}"
        if [[ -z "$FILE_PATH" ]]; then
          FILE_PATH="''${radarr_moviefile_path:-}"
        fi

        if [[ -z "$FILE_PATH" ]]; then
          echo "No file path provided by Sonarr/Radarr"
          exit 0
        fi

        # Check extension against configured list
        EXT="''${FILE_PATH##*.}"
        EXT_LOWER="''${EXT,,}"
        case "$EXT_LOWER" in
          ${extensionCase}) ;;
          *) echo "Skipping unsupported extension: $FILE_PATH"; exit 0 ;;
        esac

        # Non-blocking lock: skip if batch is running, daily will catch it
        exec ${pkgs.util-linux}/bin/flock -n /run/whisper-subtitles/lock \
          ${whisperScript} "$FILE_PATH"
      '';
    };
  };
}
