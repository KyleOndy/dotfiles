This is the daily metrics review across every host and the UniFi network.
Static alert rules fire on thresholds. Your job is what thresholds miss:
trends, drift, slow degradation, and things heading toward a limit that have
not reached it yet.

The sweep runs daily, so anything that happened (a restart, a reset, a
failure) needs only the last 24 hours. Judge whether something changed with
`baseline`, against the spread of the prior 14 days rather than one earlier
day, which can itself be high or low. Report a change only when today falls
outside that range, and say how far: today against the median and the range's
nearest edge. A bare gauge in `baseline` is one sample a day, so judge a
gauge's level with `quantile_over_time(0.5, x[1d])` and its peaks with
`max_over_time(x[1d])`. Those compare days; they are not today's level. A
day that holds a step (a deploy, a restart, a cleanup) has the median of
whichever side lasted longer, so state a current level from an instant
query and quote it beside the median. Before calling a current value a
change, read it at a 1m step over the 10 minutes around it: one sample out
of line is a spike, not a level. Fit a trend toward a limit with `predict_linear` over `[7d]`,
and only over the part after the window's last step (a restart, a deploy, a
dip and its rebound): a line across a step invents a trend. Say which window
you used. A series that a periodic job cuts back, such as a root filesystem
at the weekly nix-gc, climbs between runs: compare its peaks across runs,
not the slope inside one. nix-gc deletes only generations older than 35 days,
so one run can free little; read `{unit="nix-gc.service"} |= "freed"` before
projecting a date it fills. Call a trend steady only from each series' own
values, never from an aggregate across them.

1. Call `alerts` and `alert_rules` without a filter, so you know what is
   firing, what fired in the last 24h, and what is already watched.
2. Discover what exists with `metric_labels` (`__name__`, `job`, `host`)
   before writing queries.
3. Cover these areas:
   - Capacity: filesystem and ZFS pool fill rate and days until full, memory
     and swap pressure.
   - Hardware: SMART attributes that moved, temperatures trending up, UPS
     battery charge, runtime and load.
   - Network (unpoller): WAN latency, packet loss and throughput, AP retries
     and channel utilisation, device uptime resets that mean a reboot, client
     counts that changed shape. unpoller's VAP retry counters sum the
     stations now associated, so they drop when one leaves, and increase()
     reads that drop as a reset and adds the whole value. Count a day with
     `sum_over_time(clamp_min(delta(x[1m]), 0)[1d:1m])`, read the raw 1m
     samples before reporting a jump, and name the client whose
     `unpoller_client_transmit_retries_total` rose with it.
   - Services: scrape targets flapping (`up`), scrape duration creeping up,
     process memory that only grows, restarts.
   - Backups: last-success timestamps drifting later even when still inside
     their alert thresholds, and scrub ages past 32 days (every pool scrubs
     on the 1st, so 0-31 days is the schedule). To say when a job ran, convert its
     `*_timestamp_seconds` value to a date; never work it back from an age
     and the time you think the query ran.
4. Before writing, go through your findings and drop any that:
   - matches an entry under Acknowledged issues below. Report it only if it
     recurred or changed after the entry's date, and name the entry.
   - a fleet note in your instructions already explains, such as trex's gaps
     and disk.
   - rests on a value you did not query this run. It goes under Not checked
     instead.

   Name what you dropped, and why, under Checked.

Report up to 8 findings, ranked by how much Kyle should care, in the sweep
layout. The report starts with its bold verdict line: no title, and nothing
before it.
