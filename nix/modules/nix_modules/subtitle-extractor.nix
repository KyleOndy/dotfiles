{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.subtitleExtractor;

  # Shared extraction logic script
  # Usage: subtitle-extract <file-or-directory>
  # If given a directory, recursively finds .mkv files and processes them
  # If given a file, processes just that file
  extractionScript = pkgs.writeShellScript "subtitle-extract" ''
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

    # Function to extract subtitles from a single file
    extract_subtitles() {
      local input_file="$1"
      local base_dir=$(dirname "$input_file")
      local base_name=$(basename "$input_file" .mkv)
      local base_path="$base_dir/$base_name"

      # Get subtitle stream info as JSON
      local subtitle_streams=$(ffprobe -v error -select_streams s -show_entries \
        stream=index,codec_name:stream_tags=language,title \
        -of json "$input_file" 2>/dev/null || echo '{"streams":[]}')

      # Filter for text-based subtitle formats (skip PGS/DVD bitmap subs)
      local text_subs=$(echo "$subtitle_streams" | jq -r '
        .streams[] |
        select(.codec_name == "subrip" or .codec_name == "ass" or .codec_name == "mov_text" or .codec_name == "srt") |
        "\(.index)|\(.tags.language // "und")|\(.tags.title // "")"
      ')

      if [[ -z "$text_subs" ]]; then
        return 0
      fi

      # Track which language codes we've seen to handle duplicates
      declare -A lang_counts

      while IFS='|' read -r stream_idx lang title; do
        # Map common 3-letter codes to 2-letter (ISO 639-2 to ISO 639-1)
        case "$lang" in
          eng) lang="en" ;;
          spa) lang="es" ;;
          fre|fra) lang="fr" ;;
          ger|deu) lang="de" ;;
          ita) lang="it" ;;
          por) lang="pt" ;;
          jpn) lang="ja" ;;
          kor) lang="ko" ;;
          chi|zho) lang="zh" ;;
          rus) lang="ru" ;;
          und) lang="und" ;;
        esac

        # Determine suffix based on title (e.g., "SDH", "forced", "cc")
        local suffix=""
        if echo "$title" | grep -iq "sdh"; then
          suffix=".sdh"
        elif echo "$title" | grep -iq "forced"; then
          suffix=".forced"
        elif echo "$title" | grep -iq "cc\|closed.caption"; then
          suffix=".cc"
        fi

        # Handle duplicate languages by appending count
        local count=''${lang_counts[$lang]:-0}
        lang_counts[$lang]=$((count + 1))
        if [[ $count -gt 0 ]]; then
          suffix="$suffix.$count"
        fi

        # Construct output filename: basename.lang[.suffix].srt
        local output_file="''${base_path}.''${lang}''${suffix}.srt"

        # Skip if sidecar already exists
        if [[ -f "$output_file" ]]; then
          continue
        fi

        # Extract subtitle stream to srt format
        if ffmpeg -v error -i "$input_file" -map "0:$stream_idx" -c:s srt "$output_file" 2>/dev/null; then
          echo "Extracted: $output_file (stream $stream_idx: $lang''${title:+ - $title})"
        else
          echo "Failed to extract stream $stream_idx from $input_file" >&2
        fi
      done <<< "$text_subs"
    }

    # Main logic: process file or directory
    TARGET="$1"

    if [[ -f "$TARGET" ]]; then
      # Single file mode
      if [[ "$TARGET" == *.mkv ]]; then
        extract_subtitles "$TARGET"
      fi
    elif [[ -d "$TARGET" ]]; then
      # Directory mode: find all .mkv files
      while read -r mkv_file; do
        extract_subtitles "$mkv_file" || echo "Skipping: $mkv_file" >&2
      done < <(find "$TARGET" -type f -name "*.mkv")
    else
      echo "Error: $TARGET is not a file or directory" >&2
      exit 1
    fi
  '';
in
{
  options.systemFoundry.subtitleExtractor = {
    enable = mkEnableOption "batch subtitle extraction timer (Tier 2)";

    mediaPath = mkOption {
      type = types.path;
      description = "Root path of media library to scan for MKV files";
      example = "/mnt/media";
    };

    schedule = mkOption {
      type = types.str;
      default = "hourly";
      description = "Systemd timer schedule (OnCalendar format or shorthand like 'hourly')";
    };

    user = mkOption {
      type = types.str;
      default = "jellyfin";
      description = "User to run extraction as (must have read/write access to media)";
    };

    group = mkOption {
      type = types.str;
      default = "media";
      description = "Group to run extraction as";
    };
  };

  config = mkMerge [
    # Tier 2: Batch timer-based extraction
    (mkIf cfg.enable {
      systemd.services.subtitle-extractor = {
        description = "Batch subtitle extraction from MKV files";
        after = [
          "network.target"
          "nfs-client.target"
        ];
        requires = [ "nfs-client.target" ];

        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          ExecStart = "${extractionScript} ${cfg.mediaPath}";

          # Run at low priority to avoid impacting other services
          Nice = 19;
          IOSchedulingClass = "idle";

          # Sandbox for security
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ cfg.mediaPath ];
        };
      };

      systemd.timers.subtitle-extractor = {
        description = "Timer for batch subtitle extraction";
        wantedBy = [ "timers.target" ];

        timerConfig = {
          OnCalendar = cfg.schedule;
          Persistent = true;
          RandomizedDelaySec = "5m"; # Avoid clock alignment issues
        };
      };

      # Make extraction script available system-wide
      environment.systemPackages = [
        (pkgs.writeShellScriptBin "subtitle-extract" ''
          exec ${extractionScript} "$@"
        '')
      ];
    })

    # Tier 1 is configured per-host in host configuration.nix
    # See environment.etc."scripts/subtitle-extract-notify.sh" in wolf/configuration.nix
  ];
}
