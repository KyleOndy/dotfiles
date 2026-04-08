{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.mediaNormalizer;

  sourceCodecsStr = concatStringsSep "|" cfg.sourceCodecs;
  removeSubCodecsStr = concatStringsSep "|" cfg.removeSubtitleCodecs;

  normalizerScript = pkgs.writeShellScript "media-normalize" ''
    set -euo pipefail

    PATH="${
      lib.makeBinPath [
        pkgs.ffmpeg-headless
        pkgs.jq
        pkgs.findutils
        pkgs.coreutils
        pkgs.gnugrep
      ]
    }"

    TEMP_PATH="${cfg.tempPath}"
    SOURCE_CODECS="${sourceCodecsStr}"
    REMOVE_SUB_CODECS="${removeSubCodecsStr}"

    bitrate_for_channels() {
      case "$1" in
        1) echo "96k" ;;
        2) echo "192k" ;;
        6) echo "384k" ;;
        8) echo "512k" ;;
        *) echo "192k" ;;
      esac
    }

    normalize_file() {
      local input_file="$1"
      local temp_file="$TEMP_PATH/media-normalize-$$.mkv"

      # Probe all streams as JSON
      local streams
      streams=$(ffprobe -v error \
        -show_entries stream=index,codec_type,codec_name,channels \
        -of json "$input_file" 2>/dev/null) || return 1

      # Check if any audio streams need transcoding
      local needs_audio_transcode=false
      if echo "$streams" | jq -e ".streams[] | select(.codec_type == \"audio\") | select(.codec_name | test(\"^($SOURCE_CODECS)$\"))" >/dev/null 2>&1; then
        needs_audio_transcode=true
      fi

      # Check if any subtitle streams need removal
      local needs_sub_removal=false
      if [[ -n "$REMOVE_SUB_CODECS" ]] && echo "$streams" | jq -e ".streams[] | select(.codec_type == \"subtitle\") | select(.codec_name | test(\"^($REMOVE_SUB_CODECS)$\"))" >/dev/null 2>&1; then
        needs_sub_removal=true
      fi

      if [[ "$needs_audio_transcode" != "true" && "$needs_sub_removal" != "true" ]]; then
        return 0
      fi

      echo "Normalizing: $input_file"

      # Build per-stream audio codec arguments
      local codec_args=()
      local audio_idx=0
      while IFS=$'\t' read -r codec channels; do
        if echo "$codec" | grep -qE "^($SOURCE_CODECS)$"; then
          local bitrate
          bitrate=$(bitrate_for_channels "$channels")
          codec_args+=("-c:a:$audio_idx" "aac" "-b:a:$audio_idx" "$bitrate")
          echo "  audio:$audio_idx $codec ''${channels}ch -> aac $bitrate"
        else
          codec_args+=("-c:a:$audio_idx" "copy")
        fi
        audio_idx=$((audio_idx + 1))
      done < <(echo "$streams" | jq -r '.streams[] | select(.codec_type == "audio") | "\(.codec_name)\t\(.channels // 2)"')

      # Build subtitle map exclusions
      local sub_args=()
      if [[ "$needs_sub_removal" == "true" ]]; then
        local sub_idx=0
        while IFS=$'\t' read -r codec; do
          if echo "$codec" | grep -qE "^($REMOVE_SUB_CODECS)$"; then
            sub_args+=("-map" "-0:s:$sub_idx")
            echo "  removing subtitle:$sub_idx ($codec)"
          fi
          sub_idx=$((sub_idx + 1))
        done < <(echo "$streams" | jq -r '.streams[] | select(.codec_type == "subtitle") | .codec_name')
      fi

      # Clean up temp file on failure
      trap 'rm -f "$temp_file"' RETURN

      ffmpeg -nostdin -v error \
        -i "$input_file" \
        -map 0 \
        "''${sub_args[@]}" \
        -c:v copy \
        -c:s copy \
        -map_chapters 0 \
        "''${codec_args[@]}" \
        -f matroska \
        -y "$temp_file"

      # Sanity check output size
      local new_size
      new_size=$(stat -c%s "$temp_file")
      if [[ "$new_size" -lt 1048576 ]]; then
        echo "  ERROR: output too small (''${new_size} bytes), keeping original" >&2
        return 1
      fi

      # Preserve ownership and permissions
      local orig_owner orig_mode
      orig_owner=$(stat -c "%u:%g" "$input_file")
      orig_mode=$(stat -c "%a" "$input_file")
      chown "$orig_owner" "$temp_file"
      chmod "$orig_mode" "$temp_file"

      # Atomic replace (same filesystem)
      mv "$temp_file" "$input_file"
      trap - RETURN

      echo "  done: $input_file"
    }

    # Main: file or directory mode
    TARGET="''${1:-.}"

    if [[ -f "$TARGET" ]]; then
      if [[ "$TARGET" == *.mkv ]]; then
        normalize_file "$TARGET"
      fi
    elif [[ -d "$TARGET" ]]; then
      while read -r mkv_file; do
        normalize_file "$mkv_file" || echo "  skipping: $mkv_file" >&2
      done < <(find "$TARGET" -type f -name "*.mkv")
    else
      echo "Error: $TARGET is not a file or directory" >&2
      exit 1
    fi
  '';
in
{
  options.systemFoundry.mediaNormalizer = {
    enable = mkEnableOption "media normalizer for Roku/device compatibility";

    mediaPath = mkOption {
      type = types.path;
      default = "/mnt/storage/media";
      description = "Root path of media library to scan for MKV files";
    };

    mountPoint = mkOption {
      type = types.path;
      default = "/mnt/storage";
      description = "Mount point that must be available before the service starts";
    };

    tempPath = mkOption {
      type = types.path;
      default = "/mnt/storage/media/tmp";
      description = "Temp directory for atomic file replacement (must be on same filesystem as mediaPath)";
    };

    schedule = mkOption {
      type = types.str;
      default = "*-*-* 01:00:00";
      description = "Systemd timer schedule (OnCalendar format)";
    };

    user = mkOption {
      type = types.str;
      default = "root";
      description = "User to run normalizer as";
    };

    group = mkOption {
      type = types.str;
      default = "root";
      description = "Group to run normalizer as";
    };

    sourceCodecs = mkOption {
      type = types.listOf types.str;
      default = [ "eac3" ];
      description = "Audio codecs to replace with AAC";
      example = [
        "eac3"
        "dts"
      ];
    };

    removeSubtitleCodecs = mkOption {
      type = types.listOf types.str;
      default = [
        "hdmv_pgs_subtitle"
        "dvd_subtitle"
      ];
      description = "Subtitle codecs to strip (bitmap formats that force transcoding)";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.media-normalizer = {
      description = "Normalize media files for device compatibility (EAC3→AAC, strip bitmap subs)";
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
        ExecStart = "${normalizerScript} ${cfg.mediaPath}";
        Nice = 19;
        IOSchedulingClass = "idle";
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [
          cfg.mediaPath
          cfg.tempPath
        ];
        TimeoutStartSec = "24h";
      };
    };

    systemd.timers.media-normalizer = {
      description = "Timer for media normalization";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

    # CLI wrapper for manual runs
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "media-normalize" ''
        exec ${normalizerScript} "$@"
      '')
    ];

    # Sonarr/Radarr post-import hook
    environment.etc."scripts/media-normalize-notify.sh" = {
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

        if [[ "$FILE_PATH" != *.mkv ]]; then
          echo "Skipping non-MKV file: $FILE_PATH"
          exit 0
        fi

        exec ${normalizerScript} "$FILE_PATH"
      '';
    };
  };
}
