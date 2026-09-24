# Cogsworth Host

NixOS host config for the Raspberry Pi 5 (4GB) kiosk. App-level docs (backend, dev loop, DevTools tunnel) live in the upstream repo at `/Users/kyle/src/cogsworth/v3/CLAUDE.md`.

## Services

- `cogsworth.service`: JVM backend (`cogsworth.jar` on openjdk 21) on `:8080`, `Restart = "always"` after 2s
- `cogsworth-kiosk.service`: Sway + Chromium kiosk display, `Restart = "on-failure"` after 5s
- `cogsworth-watchdog.service` / `.timer`: health checks (runs every 30s, first run 2min after boot)
- `cogsworth-db-restore` / `cogsworth-db-snapshot` / `cogsworth-db-shutdown-snapshot`: move the SQLite DB between tmpfs and the SD card
- `cogsworth-amp-keepalive.service`: holds the MAX98357A amp's I2S stream open with silence so it never powers back on with a pop, `Restart = "always"` after 2s
- `cogsworth-brightness-init.service`: sets the display digipot to minimum brightness before the backend starts
- `wyoming-openwakeword.service`: wake word detection on `127.0.0.1:10400`
- `birdnet-go.service`: classifies bird song from the outdoor cameras' RTSP audio (`birdnet-go.nix`)
- `caddy.service`: LAN HTTP on `:80`, proxied to the backend on `127.0.0.1:8080`

## Viewing Logs

Journal is RAM-only (50M cap, 1h retention). For anything older, query Loki.

```bash
# Backend logs (calendar sync, API errors)
ssh cogsworth journalctl -u cogsworth.service -f

# Kiosk display logs, includes Chromium DevTools console output
ssh cogsworth journalctl -u cogsworth-kiosk.service -f

# Watchdog health check results
ssh cogsworth journalctl -u cogsworth-watchdog.service -f
```

### Chromium DevTools console output

Chromium runs with `--enable-logging=stderr` (no `--v=1`), so JS `console.log`, `console.error`, 404s, and resource warnings land in the `cogsworth-kiosk.service` journal. C++ internal logs (TLS, QUIC, policy) are suppressed. To filter for console-relevant lines:

```bash
ssh cogsworth 'journalctl -u cogsworth-kiosk -n 500 --no-pager' \
  | grep -iE 'CONSOLE|error|failed to load'
```

### Loki (durable, >1h)

Via Grafana Explore at `https://grafana.apps.ondy.org`:

```
{host="cogsworth", unit="cogsworth-kiosk.service"} |= "CONSOLE"
{host="cogsworth", unit="cogsworth.service"}
{host="cogsworth"} |~ "(?i)error|warn"
```

## Watchdog

Three independent checks, all in one script that the timer runs every 30s
(grep `systemd.services.cogsworth-watchdog` in `configuration.nix`). Each
keeps its own counter in `/var/lib/cogsworth-watchdog/`, resets it on the
first success, and calls `systemctl reset-failed` before restarting so a
service that hit the restart limit still recovers.

| Check          | Probe                                  | Threshold | Action                                       |
| -------------- | -------------------------------------- | --------- | -------------------------------------------- |
| Backend health | `GET 127.0.0.1:8080/api/health`        | 3 (90s)   | restart `cogsworth.service`                  |
| Kiosk renderer | `Runtime.evaluate` over CDP on `:9222` | 5 (150s)  | restart `cogsworth-kiosk.service`            |
| Off-origin     | top-frame URL is not localhost         | 3 (90s)   | `Page.navigate` back each tick, then restart |

Kiosk checks are skipped for the first 60s after a kiosk start: a cold Pi 5
takes longer than that to bring up Sway and Chromium, and the counter also
resets whenever `ActiveEnterTimestampMonotonic` changes, so failures from a
previous run never count against a new one.

Above all three, systemd feeds the Pi's hardware watchdog
(`systemd.settings.Manager.RuntimeWatchdogSec = "30s"`). `bcm2835_wdt` is
built into the rpi5 kernel rather than a loadable module, so `/dev/watchdog0`
comes up on its own and there is nothing to `lsmod` for.

```bash
# Consecutive failures per check (0 when healthy)
ssh cogsworth 'head -n99 /var/lib/cogsworth-watchdog/*count*'

# How many times the backend has restarted this boot
ssh cogsworth systemctl show cogsworth.service -p NRestarts
```

## SD Card Wear

`systemFoundry.sdCardOptimization.enable = true` puts `/tmp` (512M) and
`/var/log` (256M) on tmpfs, makes the journal volatile (50M, 1h), enables
zstd zram swap at 25% of RAM, and raises the vm.dirty ratios so writes batch.
It has no other options; the sizes live in
`nix/modules/nix_modules/sd-card-optimization.nix`. `noatime` on `/` and
`/boot/firmware` comes from `configuration.nix`, not from the module.

`/var/lib/cogsworth/db` is separately a 16M tmpfs. `cogsworth-db-restore`
copies the DB (plus `-wal` and `-shm` when present) up from
`/var/lib/cogsworth/persistent` before the backend starts.
`cogsworth-db-snapshot` copies `cogsworth.db` back every 5 minutes, and
`cogsworth-db-shutdown-snapshot` copies it once more on a clean shutdown.
Neither copies `-wal` or `-shm`.

A hard power cut therefore loses up to 5 minutes of DB writes and every log
line not yet shipped to Loki. If the app runs SQLite in WAL mode, that bound
does not hold: writes not yet checkpointed into `cogsworth.db` are in none of
the copies.

## Interactive DevTools

For live debugging, `make devtools` from the cogsworth repo root (it is not a target in this repo) opens an SSH tunnel to Chromium's remote debugging port (`localhost:9222`). See `/Users/kyle/src/cogsworth/v3/CLAUDE.md` for details.

## 60fps / Rendering

Target is steady 60fps. Hardware is Pi 5 + Mesa V3D at 1080p60 rotated portrait (sway output `transform 90`).

**Verify on-device:**

- `make devtools` (cogsworth repo) → DevTools → Rendering → Frame Rendering Stats for frame timing detail.
- DevTools → Performance → Record 10s of swipe to see what's eating frame budget.

**System-level knobs** (`nix/hosts/cogsworth/configuration.nix`):

| Setting                   | Location         | Default | Notes                                                                                                                      |
| ------------------------- | ---------------- | ------- | -------------------------------------------------------------------------------------------------------------------------- |
| `max_render_time`         | sway output line | `1`     | ms before vblank sway starts compositing; `1` is aggressive. Any hiccup drops to 30fps. Try `2`–`4` if seeing frame drops. |
| `--enable-logging=stderr` | Chromium flags   | on      | JS console output to journald; `--v=1` removed (was causing ~5–15% CPU overhead with no benefit).                          |
| `VaapiVideoDecoder`       | Chromium flags   | on      | Pi 5 has no H.264 HW decode, so this flag does nothing useful.                                                             |

**Known V3D limitations:**

- No hardware H.264 decode (VideoCore VII dropped it), so HTML5 video falls back to software.
- `mask-image` forces offscreen compositing per element; `backdrop-filter` and large `filter: blur()` are expensive.
- `box-shadow` transitions trigger full repaints (not composited).

Frontend rendering optimizations (body noise → WebP, external SVG dividers, pre-baked washi masks, clock store split, hour-slot gradient) landed in the cogsworth repo in commits `d5b29cb7` and `03c70fbc`.

## Deployment

deploy-rs sets `fastConnection = false` for cogsworth in `flake.nix`, because
it is on WiFi. `make sdcard-cogsworth` is only for a fresh card or an
unbootable Pi.
