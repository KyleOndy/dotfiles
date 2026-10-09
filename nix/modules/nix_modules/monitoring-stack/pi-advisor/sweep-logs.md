This is the daily log review. Static alert rules already cover the failure
modes Kyle knows about. Your job is what they miss.

The sweep runs daily, so anything that happened (a restart, a reset, a
failure) needs only the last 24 hours. Compare against the same 24 hours a
week earlier with `offset 7d`. Look further back only to explain something
that moved, and say which window you used.

1. Call `alerts` and `alert_rules` without a filter, so you know what is
   already firing and what is already watched.
2. Journal volume and errors by host and unit, now against a week ago, e.g.
   `sum by (host, unit) (count_over_time({job="systemd-journal"} |~ "(?i)(error|fail|panic|denied|refused|timed? ?out)" [24h]))`
   and the same with `offset 7d`. Look for units that are new to the list,
   units whose count jumped, and units that went quiet when they normally log.
3. Caddy access: 5xx counts by host and upstream, 4xx spikes, and request
   patterns that look like scanning or credential stuffing against a public
   app.
4. Read raw lines only for the handful of changes that stood out, enough to
   say what the errors are.

Report up to 8 findings, ranked by how much Kyle should care, each with its
evidence and a suggested next step. End with one line naming the areas you
checked that looked normal.
