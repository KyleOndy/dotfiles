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
        startAt = "*-*-* *:00:00"; # hourly
        path = with pkgs; [
          fd
          ripgrep
          rsync
          yt-dlp
        ];
        script = ''
          mkdir -p "${cfg.temp_dir}"

          main() {
            # TODO: Break out the cleanup process to own service
            # remove watched episodes. this will remove anything that has been started.
            echo "==> REMOVING THE FOLLOWING"
            while IFS= read -r -d $'\0' file; do
              if [[ -f "$file" ]]; then
                rm -v "$file"
              fi
            done < <(journalctl --since="-1 week" --until="-${cfg.delete_grace_period}" -u jellyfin.service | rg --null-data --only-matching --replace='$1' 'Path=(${cfg.media_dir}.*?), AudioStream')
            echo "==> DONE REMOVING"

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
            echo " downloading: https://www.youtube.com/$channel_name/videos"
            yt-dlp "https://www.youtube.com/$channel_name/videos" \
              --quiet \
              --download-archive "${cfg.data_dir}/youtube-dl-seen.conf" \
              --prefer-free-formats \
              --ignore-errors \
              --mark-watched \
              --write-auto-sub \
              --embed-subs \
              --add-metadata \
              --concurrent-fragments=20 \
              --compat-options no-live-chat \
              --match-filter "!is_live" \
              --playlist-end 25 \
              --output "${cfg.temp_dir}/%(uploader)s/%(upload_date)s - %(uploader)s - %(title)s [%(id)s].%(ext)s"
          }

          main
        '';
      };
      timers.yt-dowload-and-clean.timerConfig.RandomizedDelaySec = "15m";
    };
  };
}


