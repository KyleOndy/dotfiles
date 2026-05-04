# Cogsworth Host

NixOS host config for the Raspberry Pi 5 (4GB) kiosk. App-level docs (Go backend, dev loop, DevTools tunnel) live in the upstream repo at `/home/kyle/src/cogsworth/v3/CLAUDE.md`.

## Services

- `cogsworth.service` — Go backend on `:8080`
- `cogsworth-kiosk.service` — Sway + Chromium kiosk display
- `cogsworth-watchdog.service` / `.timer` — HTTP health check for the backend (runs every 30s)

## Viewing Logs

Journal is RAM-only (50M cap, 1h retention). For anything older, query Loki.

```bash
# Backend logs (calendar sync, API errors)
ssh cogsworth journalctl -u cogsworth.service -f

# Kiosk display logs — includes Chromium DevTools console output
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

## Watchdog State

```bash
# Consecutive health-check failures (resets to 0 on success or restart)
ssh cogsworth cat /var/lib/cogsworth-watchdog/failure_count

# How many times the backend has restarted this boot
ssh cogsworth systemctl show cogsworth.service -p NRestarts
```

## Interactive DevTools

For live debugging, `make devtools` from the repo root opens an SSH tunnel to Chromium's remote debugging port (`localhost:9222`). See `/home/kyle/src/cogsworth/v3/CLAUDE.md` for details.

## 60fps / Rendering

Target is steady 60fps. Hardware is Pi 5 + Mesa V3D at 1080p60 rotated portrait (sway output `transform 90`).

**Verify on-device:**

- `--show-fps-counter` is enabled — the number is visible top-right on the physical display.
- `make devtools` → DevTools → Rendering → Frame Rendering Stats for frame timing detail.
- DevTools → Performance → Record 10s of swipe to see what's eating frame budget.

**System-level knobs** (`nix/hosts/cogsworth/configuration.nix`):

| Setting                   | Location         | Default | Notes                                                                                                                       |
| ------------------------- | ---------------- | ------- | --------------------------------------------------------------------------------------------------------------------------- |
| `max_render_time`         | sway output line | `1`     | ms before vblank sway starts compositing; `1` is aggressive — any hiccup drops to 30fps. Try `2`–`4` if seeing frame drops. |
| `--enable-logging=stderr` | Chromium flags   | on      | JS console output to journald; `--v=1` removed (was causing ~5–15% CPU overhead with no benefit).                           |
| `VaapiVideoDecoder`       | Chromium flags   | on      | Pi 5 has no H.264 HW decode — this flag does nothing useful.                                                                |

**Known V3D limitations:**

- No hardware H.264 decode (VideoCore VII dropped it) — HTML5 video falls back to software.
- `mask-image` forces offscreen compositing per element; `backdrop-filter` and large `filter: blur()` are expensive.
- `box-shadow` transitions trigger full repaints (not composited).

Frontend rendering optimizations (body noise → WebP, external SVG dividers, pre-baked washi masks, clock store split, hour-slot gradient) landed in commits `d5b29cb7` and `03c70fbc`.

## Deployment

No deploy-rs wiring for cogsworth yet — changes require rebuilding the SD image:

```bash
make sdcard-cogsworth
```
