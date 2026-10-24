This is the daily playback review: Jellyfin on tiger and the clients that
play from it, Rokus above all. Find the plays that failed, stalled or
degraded in the last 24 hours, and work out why. Judge whether a count
changed with `baseline`, against the spread of the prior 14 days.

Where the evidence lives:

- `jellyfin_now_playing_state` holds one series per play while it runs,
  labelled `username`, `device`, `method` (`directplay` or `transcode`),
  `title` and `series_title`, sampled every 15 seconds. List `device`
  values with `metric_labels` rather than assuming them.
- `{unit="jellyfin.service"}` is Jellyfin's own log, debug lines for
  transcoding included. The journal renders its strings without quotes:
  `RemoteIP: 10.24.89.98`, not `RemoteIP: "10.24.89.98"`.
- `{job="jellyfin-ffmpeg"}` is ffmpeg's output for each transcode, remux or
  direct stream, one `filename` per ffmpeg run. A seek starts a new run.
  It has no lines before its first day, so `baseline` days that read zero
  before then are not a change.
- unpoller's `unpoller_client_*` series, by `name` and `ip`, are each
  client's Wi-Fi link. `unpoller_client_radio_transmit_rate_bps` is the
  AP's rate to the client.
- `{job="caddy-access", vhost=~"jellyfin.*"}` covers remote clients only.
  Its `uri` carries `TranscodeReasons=` for each transcode it asks for.

Steps:

1. Call `alerts` and `alert_rules` filtered on `jellyfin`.
2. What played: `jellyfin_now_playing_state` over 24h, by `username`,
   `device`, `method` and `title`. A title played on several devices, or
   started again and again on one, is a lead.
3. Failure lines in the journal, counted by line and run through
   `baseline`:
   - `Playback stopped reported by app` with `Stopped at 0 ms`: the player
     gave up before the first frame. Several stops for one title within
     minutes are the client retrying.
   - `cannot serve` (DynamicHlsController): the player asked for a segment
     after its ffmpeg had ended.
   - `A task was canceled. URL GET /videos/`: the client dropped a segment
     download part way.
   - `Transcoding kill timer stopped`: the client went silent for 60s
     without reporting a stop.
   - `FFmpeg exited with code` other than 0. 137 is SIGKILL.
   - `Not throttling transcoder gap -`: a negative gap means the player has
     caught up with ffmpeg and is starved. `Throttling transcoder gap` and
     `Sending pause command` are Jellyfin holding back an ffmpeg that is
     180 seconds ahead, which is normal.
4. For each play that stood out, read its ffmpeg runs: the command line
   (`-codec:v:0 copy` is video passed through, `h264_qsv` or `hevc_qsv` is
   a GPU encode, `libmp3lame` is audio converted), the input's streams,
   any line with `Error`, `Invalid data` or `Conversion failed`, and its
   `speed=`. Speed below 1x while unthrottled means tiger could not keep
   up. Runs seconds apart are someone scrubbing when their `-ss` moves and
   the client retrying when it repeats.
5. Name the client: the `RemoteIP:` line Jellyfin logs when the play
   starts, then `unpoller_client_uptime_seconds{ip="<address>"}`. For a
   Roku on Wi-Fi that stalled, compare its
   `unpoller_client_radio_transmit_rate_bps`, `unpoller_client_radio_signal_db`
   and `unpoller_client_satisfaction_ratio` over the play with the other
   clients on its `ap_name`. A rate pinned low for days while a neighbour
   on the same AP runs fast is the AP's rate control stuck on that client.
6. Decide where each failure sits: the file (codec, bad data), the client
   (a codec it claims and cannot play, a retry with no fallback), tiger
   (speed below 1x, GPU errors), or the network (a low or falling link
   rate, dropped downloads). Use `web_search` on the client's app version
   and the error signature for a known upstream bug.
7. Before writing, drop any finding that matches an entry under
   Acknowledged issues below, or that rests on lines you did not read this
   run, and name what you dropped, and why, under Checked.

A quiet day with nothing played is not a finding. Report up to 8 findings,
ranked by how much Kyle should care, in the sweep layout. The report starts
with its bold verdict line: no title, and nothing before it.
