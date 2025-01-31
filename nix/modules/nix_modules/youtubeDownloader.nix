{ lib, pkgs, config, ... }:
with lib;
let cfg = config.systemFoundry.youtubeDownloader;
in
{
  options.systemFoundry.youtubeDownloader = {
    enable = mkEnableOption ''
      Automatacilly download youtube videos and cleanup after watching
    '';
    media_dir = mkOption {
      type = types.path;
      description = "Directory to media should be moved to";
      default = "/var/lib/youtube-downloader";
    };
    data_dir = mkOption {
      type = types.path;
      description = "Directory to store data";
      default = "/var/lib/youtube-downloader";
    };
    temp_dir = mkOption {
      type = types.path;
      description = "Directory to temparary files";
      default = "${cfg.data_dir}/temp";
    };
    delete_grace_period = mkOption {
      type = types.str;
      description = "Timespan to keep videos on jellyfin before deleting";
      default = "36 hours";
    };
    watched_channels = mkOption {
      type = types.listOf types.str;
      description = "List of channels in @channel_name to watch";
    };
  };

  config = mkIf cfg.enable {

    systemd = {
      services.yt-dowload-and-clean = {
        enable = true;
        description = "Downloads Youtube videos and cleans up Jellyfin";
        startAt = "*-*-* 4:00:00"; # 4 am
        path = with pkgs; [
          fd
          ripgrep
          rsync
          yt-dlp
        ];
        script = ''
          mkdir -p "${cfg.temp_dir}"

          main() {
            echo "yt-dlp version: $(yt-dlp --version)" # for debugging
            # TODO: Break out the cleanup process to own service
            # remove watched episodes. this will remove anything that has been started.
            #echo "==> REMOVING THE FOLLOWING"
            #while IFS= read -r -d $'\0' file; do
            #  if [[ -f "$file" ]]; then
            #    rm -v "$file"
            #  fi
            #done < <(journalctl --since="-1 week" --until="-${cfg.delete_grace_period}" -u jellyfin.service | rg --null-data --only-matching --replace='$1' 'file:"(/mnt/media/yt.*?)" -threads')
            #echo "==> DONE REMOVING"

            # Download new videos
            for channel in ${concatStringsSep " " cfg.watched_channels}; do
              download "$channel"
            done

            # move into jellyfin dir
            if [[ -z $(ls -A "${cfg.temp_dir}"/* 2>/dev/null) ]]; then
              echo "No downloads"
            else
              rsync -ahv --remove-source-files "${cfg.temp_dir}"/* "${cfg.media_dir}"
            fi

            # remove leftovers from incomplete downloads
            fd \
              --extension=part \
              --extension="temp.webm" \
              --extension=meta \
              --extension=en.vtt \
              . /mnt/media/yt -x rm
            fd --type=f 'f[0-9]+\.webm' "${cfg.media_dir}" -x rm

            # remove empty dirs
            fd --type=empty --type=directory . "${cfg.media_dir}" "${cfg.temp_dir}" -x rmdir

            # TODO: start sync of jellyfin media library
            # curl -v -X GET -H "X-MediaBrowser-Token: TOKEN" https://jellyfin.tld/library/refresh

            vids=$(fd --type=f . "${cfg.media_dir}" -x echo '{/}' | sort)
            echo "total videos: $(echo "$vids" | wc -l)"
          }

          download() {
            local channel_name=$1
            echo "downloading: https://www.youtube.com/$channel_name"
            yt-dlp "https://www.youtube.com/$channel_name" \
              --quiet \
              --download-archive "${cfg.data_dir}/youtube-dl-seen.conf" \
              --prefer-free-formats \
              --format 'bestvideo[format_note!*=Premium]+bestaudio' \
              --ignore-errors \
              --mark-watched \
              --write-auto-sub \
              --embed-subs \
              --embed-metadata \
              --parse-metadata "$TITLE:%(title)s" \
              --concurrent-fragments=20 \
              --compat-options no-live-chat \
              --match-filter "!is_live" \
              --playlist-end 25 \
              --output "${cfg.temp_dir}/%(uploader)s/%(upload_date)s - %(uploader)s - %(title)s [%(id)s].%(ext)s" || true
          }

          main
        '';
      };
      timers.yt-dowload-and-clean.timerConfig.RandomizedDelaySec = "15m";
    };
  };
}


