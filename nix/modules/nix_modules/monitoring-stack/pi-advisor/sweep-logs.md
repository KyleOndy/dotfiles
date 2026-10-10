This is the daily log review. Static alert rules already cover the failure
modes Kyle knows about. Your job is what they miss.

The sweep runs daily, so anything that happened (a restart, a reset, a
failure) needs only the last 24 hours. Judge whether a count changed with
`baseline`, against the spread of the prior 14 days rather than one earlier
day, which can itself be high or low. Report a change only when today falls
outside that range, and say how far.

1. Call `alerts` and `alert_rules` without a filter, so you know what is
   already firing and what is already watched.
2. Journal volume and errors by host and unit, e.g.
   `sum by (host, unit) (count_over_time({job="systemd-journal"} |~ "(?i)(error|fail|panic|denied|refused|timed? ?out)" [24h]))`
   and the same with `offset 7d`, to find units that are new to the list or
   went quiet when they normally log. Run `baseline` on each unit whose count
   looks high, one unit at a time.
3. Caddy access: 5xx counts by host and upstream, 4xx spikes, and request
   patterns that look like scanning or credential stuffing against a public
   app.
4. Read raw lines only for the handful of changes that stood out, enough to
   say what the errors are. Before calling a count a jump, run `baseline` on
   the specific line that stood out (`|= "<text>"`), not only the broad
   regex.

Report up to 8 findings, ranked by how much Kyle should care, in the sweep
layout.
