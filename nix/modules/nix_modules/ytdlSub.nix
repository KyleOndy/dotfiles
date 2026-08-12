{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.ytdlSub;

  displayName = handle: removePrefix "@" handle;

  # The Videos tab, not the bare handle. A bare handle expands to every tab the
  # channel has, and each one gets its own playlistend, so max_videos silently
  # means "per tab" and the Shorts tab comes along with it.
  channelUrl = handle: "https://www.youtube.com/${handle}/videos";

  # ytdl-sub reads "= Genre" keys as a preset override that tags every
  # subscription under it, which is what puts the genre on the Jellyfin entry.
  subscriptions = mapAttrs' (
    genre: handles:
    nameValuePair "= ${genre}" (
      listToAttrs (map (h: nameValuePair (displayName h) (channelUrl h)) handles)
    )
  ) cfg.channels;

  # Jellyfin creates .trickplay directories under the media root as its own
  # user; without this ytdl-sub cannot descend into them to move files.
  fixTrickplayPerms = pkgs.writeShellScript "fix-trickplay-perms" ''
    ${pkgs.findutils}/bin/find ${cfg.media_dir} -path '*.trickplay*' -type d \
      -exec chmod g+rwX {} +
  '';

  textfile = "/var/lib/prometheus-node-exporter-text-files/ytdl_sub.prom";

  # Where CacheDirectory below lands it.
  cacheDir = "/var/cache/ytdl-sub";

  instance = config.services.ytdl-sub.instances.youtube;
  yamlFormat = pkgs.formats.yaml { };

  # Restated in full because the upstream module builds ExecStart inline with
  # no hook to append a flag. The two files regenerate to upstream's own store
  # paths: same generator, same option values.
  #
  # --shuffle because YouTube's bot check trips partway into a run and refuses
  # everything after it, so a fixed order starves whichever channels sort last
  # every single night. ytdl-sub shuffles after presets resolve, leaving the
  # genre tags intact.
  execStart = concatStringsSep " " [
    (getExe config.services.ytdl-sub.package)
    "--config ${yamlFormat.generate "config.yaml" instance.config}"
    "sub ${yamlFormat.generate "subscriptions.yaml" instance.subscriptions}"
    "--shuffle"
  ];
in
{
  options.systemFoundry.ytdlSub = {
    enable = mkEnableOption "ytdl-sub YouTube channel downloader";

    media_dir = mkOption {
      type = types.path;
      default = "/var/lib/ytdl-sub/media";
      description = "Output directory for completed videos";
    };

    data_dir = mkOption {
      type = types.path;
      default = "/var/lib/ytdl-sub/youtube";
      description = "State directory for logs and download archives";
    };

    temp_dir = mkOption {
      type = types.path;
      default = "/var/lib/ytdl-sub/tmp";
      description = "Working directory for in-progress downloads";
    };

    max_videos = mkOption {
      type = types.ints.positive;
      default = 1;
      description = ''
        How far back into each channel's Videos tab to look on every run.
        This is a lookback window, not a download count: entries already in
        the download archive are skipped, so a steady-state run downloads
        nothing. Raise it to backfill.
      '';
    };

    schedule = mkOption {
      type = types.str;
      default = "*-*-* 02:00:00";
      description = "Systemd calendar expression for the download run";
    };

    randomizedDelay = mkOption {
      type = types.str;
      default = "1h";
      description = ''
        Upper bound on a delay added to each run, as a systemd time span.
        systemd re-rolls it per iteration, so runs land anywhere in
        [schedule, schedule + this].
      '';
    };

    channels = mkOption {
      type = types.attrsOf (types.listOf types.str);
      description = ''
        Channels grouped by genre, as "@handle" strings. The genre becomes the
        Jellyfin genre tag.
      '';
      example = {
        Cycling = [ "@BeauMiles" ];
        Maker = [ "@colinfurze" ];
      };
    };

    housekeeping = {
      enable = mkEnableOption "daily prune and freshness metrics" // {
        default = true;
      };

      jellyfinUrl = mkOption {
        type = types.str;
        default = "http://127.0.0.1:8096";
        description = "Base URL for the local Jellyfin API";
      };

      apiKeyFile = mkOption {
        type = types.path;
        description = "File holding a Jellyfin API token";
      };

      jellyfinUser = mkOption {
        type = types.str;
        description = ''
          Jellyfin username whose play state decides what is watched. Only this
          user's history counts, so a video another account has finished is
          still kept until this one watches it or the backstop expires it.
        '';
      };

      watchedGraceDays = mkOption {
        type = types.ints.positive;
        default = 2;
        description = "Days a watched video is kept after it was last played";
      };

      unwatchedMaxDays = mkOption {
        type = types.ints.positive;
        default = 90;
        description = ''
          Days an unwatched video is kept, measured from file birth time and so
          from when it was downloaded, not when it was published. Back catalogue
          pulled by a widened `max_videos` gets the full window.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    services.ytdl-sub = {
      package = pkgs.master.ytdl-sub;
      group = "media";

      instances.youtube = {
        enable = true;
        schedule = cfg.schedule;
        readWritePaths = [
          cfg.media_dir
          cfg.temp_dir
          cfg.data_dir
        ];

        config = {
          configuration = {
            working_directory = mkForce cfg.temp_dir;
            persist_logs = {
              logs_directory = "${cfg.data_dir}/logs";
              keep_successful_logs = true;
            };
          };

          presets.base = {
            preset = [ "Jellyfin TV Show by Date" ];

            chapters.embed_chapters = true;

            subtitles = {
              embed_subtitles = true;
              languages = [ "en" ];
              allow_auto_generated_subtitles = true;
            };

            # No player_client, no cookiefile, no PO token provider. Pinning
            # player_client to "web" is what produced format-18-only downloads
            # through spring 2026: YouTube serves that client SABR-only, yt-dlp
            # cannot read SABR, and itag 18 is the one format exempt from the
            # PO token check, so 360p was all that survived. yt-dlp's own
            # default client set reaches 2160p from this host unauthenticated.
            ytdl_options = {
              noprogress = true;
              playlistend = cfg.max_videos;

              # The unit's home is /var/empty and ProtectHome seals it, so the
              # default ~/.cache/yt-dlp cannot be created and the player
              # signature functions are re-solved from scratch every run.
              cachedir = cacheDir;

              # The presets halt at the first video already held, which leaves
              # max_videos unable to reach anything behind the newest video.
              break_on_existing = false;
            };

            # Shorts are excluded by requesting the Videos tab. A /shorts/ URL
            # test cannot do it: one passed a 73 second 1080x1920 Short.
            match_filters.filters = [
              "duration>60"
              "availability != subscriber_only & availability != premium_only & availability != needs_auth"
            ];

            overrides.tv_show_directory = cfg.media_dir;
          };
        };

        subscriptions.base = subscriptions;
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.media_dir} 0775 ytdl-sub media -"
      "d ${cfg.temp_dir} 0775 ytdl-sub media -"
      "d ${cfg.data_dir} 0775 ytdl-sub media -"
      "d ${cfg.data_dir}/logs 0775 ytdl-sub media -"
    ];

    systemd.services.ytdl-sub-youtube = {
      serviceConfig = {
        ExecStartPre = "+${fixTrickplayPerms}";
        Nice = 19;
        IOSchedulingClass = "idle";

        CacheDirectory = "ytdl-sub";

        ExecStart = mkForce execStart;

        # ytdl-sub exits 1 if any single video failed, so one video pulled
        # private fails a run that fetched every other channel. A run that
        # stops downloading for real surfaces as YtdlSubStalled at 7 days.
        SuccessExitStatus = 1;
      };
    };

    systemd.timers.ytdl-sub-youtube.timerConfig.RandomizedDelaySec = cfg.randomizedDelay;

    systemd.services.ytdl-sub-housekeeping = mkIf cfg.housekeeping.enable {
      description = "Prune watched and expired ytdl-sub videos, export freshness";
      after = [ "network.target" ];

      path = [
        pkgs.curl
        pkgs.jq
        pkgs.coreutils
        pkgs.findutils
      ];

      # root, like the other textfile producers: the .prom directory is
      # root-owned 0755 and the sops API key is 0440.
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };

      script =
        let
          hk = cfg.housekeeping;
        in
        ''
          set -euo pipefail

          readonly OUTFILE="${textfile}"
          readonly MEDIA_DIR="${cfg.media_dir}"
          readonly API="${hk.jellyfinUrl}"
          readonly STATE="${cfg.data_dir}/prune-counters"
          now=$(date +%s)

          work=$(mktemp -d)
          trap 'rm -rf "$work"' EXIT

          is_video() { case "$1" in *.mp4|*.mkv|*.webm) return 0;; *) return 1;; esac; }

          drop() {
            local f="$1" base="''${1%.*}"
            rm -vf "$f" "$base.nfo" "$base.info.json" "$base-thumb.jpg"
          }

          # Cumulative across runs, because the textfile collector rewrites the
          # whole file each time and a counter that restarts at zero every day
          # cannot be rated.
          pruned_watched=0 pruned_expired=0
          if [ -r "$STATE" ]; then
            read -r pruned_watched pruned_expired < "$STATE" || true
          fi
          [ "''${pruned_watched:-x}" -ge 0 ] 2>/dev/null || pruned_watched=0
          [ "''${pruned_expired:-x}" -ge 0 ] 2>/dev/null || pruned_expired=0

          collect_gauges() {
            newest=0 count=0 bytes=0
            while IFS= read -r -d ''' f; do
              is_video "$f" || continue
              born=$(stat -c %W "$f" 2>/dev/null || echo 0)
              if [ "$born" -gt "$newest" ]; then newest="$born"; fi
              size=$(stat -c %s "$f" 2>/dev/null || echo 0)
              count=$(( count + 1 ))
              bytes=$(( bytes + size ))
            done < <(find "$MEDIA_DIR" -type f -print0 2>/dev/null)
          }

          write_metrics() {
            {
              printf '# HELP ytdl_sub_videos_total Video files currently held\n'
              printf '# TYPE ytdl_sub_videos_total gauge\n'
              printf 'ytdl_sub_videos_total %s\n' "$count"
              printf '# HELP ytdl_sub_bytes_total Bytes of video currently held\n'
              printf '# TYPE ytdl_sub_bytes_total gauge\n'
              printf 'ytdl_sub_bytes_total %s\n' "$bytes"
              printf '# HELP ytdl_sub_housekeeping_last_run_timestamp_seconds Unix time of the last sweep\n'
              printf '# TYPE ytdl_sub_housekeeping_last_run_timestamp_seconds gauge\n'
              printf 'ytdl_sub_housekeeping_last_run_timestamp_seconds %s\n' "$now"
              printf '# HELP ytdl_sub_pruned_watched_total Videos deleted after being watched\n'
              printf '# TYPE ytdl_sub_pruned_watched_total counter\n'
              printf 'ytdl_sub_pruned_watched_total %s\n' "$pruned_watched"
              printf '# HELP ytdl_sub_pruned_expired_total Videos deleted unwatched at the retention horizon\n'
              printf '# TYPE ytdl_sub_pruned_expired_total counter\n'
              printf 'ytdl_sub_pruned_expired_total %s\n' "$pruned_expired"
              # Emitted only once something has landed, so a cold start does not
              # read as a seven-day-old stall before the first download.
              if [ "$newest" -gt 0 ]; then
                printf '# HELP ytdl_sub_last_download_timestamp_seconds Birth time of the newest video held\n'
                printf '# TYPE ytdl_sub_last_download_timestamp_seconds gauge\n'
                printf 'ytdl_sub_last_download_timestamp_seconds %s\n' "$newest"
              fi
            } > "$OUTFILE.tmp"
            mv "$OUTFILE.tmp" "$OUTFILE"
          }

          # Written before the sweeps as well as after, so a Jellyfin outage
          # cannot blank the freshness gauge and trip the staleness alert.
          collect_gauges
          write_metrics

          key=$(cat ${hk.apiKeyFile})
          auth="Authorization: MediaBrowser Token=\"$key\""

          # Tolerated rather than fatal: the metrics above are already written,
          # and the backstop below still has work to do if Jellyfin is down.
          uid=$(curl -sSf --max-time 30 -H "$auth" "$API/Users" 2>/dev/null \
            | jq -r --arg n "${hk.jellyfinUser}" '.[] | select(.Name == $n) | .Id' || true)

          if [ -z "$uid" ]; then
            echo "no Jellyfin user named ${hk.jellyfinUser}, skipping the watched sweep" >&2
          else
            cutoff=$(date -u -d "@$(( now - ${toString hk.watchedGraceDays} * 86400 ))" +%Y-%m-%dT%H:%M:%SZ)
            # Selected by path rather than by library id. Jellyfin's two views
            # disagree on a library's name (/Library/VirtualFolders called this
            # one "YouTube" while /Library/MediaFolders called the same folder
            # "Shows2"), and a name lookup that misses fails silently, sweeping
            # nothing forever. The path under media_dir is unambiguous.
            # LastPlayedDate is Zulu ISO8601, so a lexical compare orders it.
            curl -sSf --max-time 120 -H "$auth" \
              "$API/Items?userId=$uid&recursive=true&includeItemTypes=Episode&fields=Path&enableUserData=true&enableImages=false&enableTotalRecordCount=false" \
              > "$work/items.json" || true

            jq -r --arg cutoff "$cutoff" --arg root "$MEDIA_DIR/" '
                .Items[]
                | select(.UserData.Played == true)
                | select(.Path != null and (.Path | startswith($root)))
                | select((.UserData.LastPlayedDate // "9999") < $cutoff)
                | .Path' "$work/items.json" > "$work/watched" || true

            # Announced, not pruned. Without this a watched video inside its
            # grace window is indistinguishable from one the sweep never saw,
            # and the difference only shows up as an absence days later.
            jq -r --arg cutoff "$cutoff" --arg root "$MEDIA_DIR/" \
                  --argjson grace ${toString hk.watchedGraceDays} '
                .Items[]
                | select(.UserData.Played == true)
                | select(.Path != null and (.Path | startswith($root)))
                | select(.UserData.LastPlayedDate != null)
                | select(.UserData.LastPlayedDate >= $cutoff)
                | "will prune \(.Path | split("/") | last) on " +
                  ((.UserData.LastPlayedDate | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)
                    + $grace * 86400 | strftime("%Y-%m-%d"))' "$work/items.json" || true

            # Redirected from a file rather than piped, because a pipe puts the
            # loop in a subshell and the counter increment would be discarded.
            while IFS= read -r f; do
              if [ -n "$f" ] && [ -f "$f" ]; then
                drop "$f"
                pruned_watched=$(( pruned_watched + 1 ))
              fi
            done < "$work/watched"
          fi

          # Backstop. %W is ZFS birth time, so this measures shelf life on disk
          # and never the upload date.
          horizon=$(( now - ${toString hk.unwatchedMaxDays} * 86400 ))
          while IFS= read -r -d ''' f; do
            is_video "$f" || continue
            born=$(stat -c %W "$f" 2>/dev/null || echo 0)
            [ "$born" -gt 0 ] || continue
            if [ "$born" -lt "$horizon" ]; then
              drop "$f"
              pruned_expired=$(( pruned_expired + 1 ))
            fi
          done < <(find "$MEDIA_DIR" -type f -print0 2>/dev/null)

          printf '%s %s\n' "$pruned_watched" "$pruned_expired" > "$STATE.tmp"
          mv "$STATE.tmp" "$STATE"

          collect_gauges
          write_metrics

          find "$MEDIA_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true

          curl -sSf --max-time 30 -X POST -o /dev/null -H "$auth" "$API/Library/Refresh" \
            || echo "library refresh failed, Jellyfin will catch up on its own scan" >&2
        '';
    };

    systemd.timers.ytdl-sub-housekeeping = mkIf cfg.housekeeping.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 06:00:00";
        Persistent = true;
      };
    };
  };
}
