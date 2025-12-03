{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.av1Transcoder;
in
{
  options.systemFoundry.av1Transcoder = {
    enable = mkEnableOption "AV1 to H.264 transcoding service";

    mediaPath = mkOption {
      type = types.str;
      default = "/mnt/media";
      description = "Path to media directory to scan for AV1 files";
    };

    quality = mkOption {
      type = types.int;
      default = 20;
      description = "QSV encoding quality (lower = better, range 1-51, similar to CRF)";
    };

    enableTimer = mkOption {
      type = types.bool;
      default = false;
      description = "Enable automatic daily scanning for new AV1 files";
    };

    timerSchedule = mkOption {
      type = types.str;
      default = "03:00";
      description = "Time to run daily scan (format: HH:MM)";
    };

    dryRun = mkOption {
      type = types.bool;
      default = false;
      description = "Preview what would be transcoded without actually transcoding";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.av1-transcode = {
      description = "Transcode AV1 media files to H.264 using Intel QSV";
      path = with pkgs; [
        jellyfin-ffmpeg
        coreutils
        findutils
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "jellyfin";
        Group = "media";
        SupplementaryGroups = [
          "render"
          "video"
        ];
      };
      script = ''
        set -euo pipefail

        MEDIA_PATH="${cfg.mediaPath}"
        QUALITY="${toString cfg.quality}"
        DRY_RUN="${if cfg.dryRun then "true" else "false"}"

        echo "Starting AV1 transcoding scan in $MEDIA_PATH"
        echo "Quality: $QUALITY, Dry run: $DRY_RUN"

        # Counter for statistics
        total_found=0
        total_transcoded=0
        total_failed=0

        # Find all MKV files and check for AV1 codec
        while IFS= read -r -d "" file; do
          codec=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=codec_name \
            -of csv=p=0 "$file" 2>/dev/null || echo "unknown")

          if [ "$codec" = "av1" ]; then
            total_found=$((total_found + 1))
            echo "Found AV1 file ($total_found): $file"

            if [ "$DRY_RUN" = "true" ]; then
              echo "  [DRY RUN] Would transcode this file"
              continue
            fi

            temp_file="''${file}.transcoding.tmp.mkv"

            echo "  Transcoding to H.264 (QSV)..."
            if ffmpeg -hwaccel qsv -hwaccel_output_format qsv \
              -i "$file" \
              -c:v h264_qsv -preset medium -global_quality "$QUALITY" \
              -c:a copy -c:s copy \
              -y "$temp_file" 2>&1 | grep -E "(frame=|error|Error|failed)"; then

              # Check if output file was created and has content
              if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
                echo "  Transcode successful, replacing original"
                mv "$temp_file" "$file"
                total_transcoded=$((total_transcoded + 1))
                echo "  Completed: $file"
              else
                echo "  ERROR: Transcode failed - output file missing or empty"
                rm -f "$temp_file"
                total_failed=$((total_failed + 1))
              fi
            else
              echo "  ERROR: ffmpeg failed"
              rm -f "$temp_file"
              total_failed=$((total_failed + 1))
            fi
          fi
        done < <(find "$MEDIA_PATH" -name "*.mkv" -type f -print0 2>/dev/null)

        echo ""
        echo "=== Transcoding Summary ==="
        echo "AV1 files found: $total_found"
        if [ "$DRY_RUN" = "true" ]; then
          echo "DRY RUN - No files were modified"
        else
          echo "Successfully transcoded: $total_transcoded"
          echo "Failed: $total_failed"
        fi
      '';
    };

    # Optional timer for automatic daily scanning
    systemd.timers.av1-transcode = mkIf cfg.enableTimer {
      description = "Daily AV1 transcoding timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.timerSchedule;
        Persistent = true; # Run on next boot if system was off
      };
    };
  };
}
