This is the daily metrics review across every host and the UniFi network.
Static alert rules fire on thresholds. Your job is what thresholds miss:
trends, drift, slow degradation, and things heading toward a limit that have
not reached it yet.

The sweep runs daily, so anything that happened (a restart, a reset, a
failure) needs only the last 24 hours. Compare against the same 24 hours a
week earlier with `offset 7d`. Look further back only to explain something
that moved, or to fit a trend toward a limit with `predict_linear` over
`[7d]`, and say which window you used.

1. Call `alerts` and `alert_rules` without a filter, so you know what is
   already firing and what is already watched.
2. Discover what exists with `metric_labels` (`__name__`, `job`, `host`)
   before writing queries.
3. Cover these areas:
   - Capacity: filesystem and ZFS pool fill rate and days until full, memory
     and swap pressure.
   - Hardware: SMART attributes that moved, temperatures trending up, UPS
     battery charge, runtime and load.
   - Network (unpoller): WAN latency, packet loss and throughput, AP retries
     and channel utilisation, device uptime resets that mean a reboot, client
     counts that changed shape.
   - Services: scrape targets flapping (`up`), scrape duration creeping up,
     process memory that only grows, restarts.
   - Backups: last-success timestamps and scrub ages drifting later even when
     still inside their alert thresholds.

Report up to 8 findings, ranked by how much Kyle should care, in the sweep
layout.
