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

   ```logql
   sum by (host, unit) (count_over_time({job="systemd-journal"} |~ `(?i)\b(error|fail(s|ed|ure|ing)?|panic|denied|refused|timed? ?out)\b|exception\b` [24h]))
   ```

   The backtick string keeps `\b` literal. Matching whole words leaves out
   unit descriptions ("vdev errors"), alert names ("SyncFailing") and empty
   fields (`"errors":0`), and still counts "Failed to start" and
   "TimeoutException".

   Run it again with `offset 7d`, to find units that are new to the list or
   went quiet when they normally log. Run `baseline` on each unit whose count
   looks high, one unit at a time. A unit that went quiet is a finding only
   if it stopped running
   (`node_systemd_unit_state{host="<host>",name="<unit>",state="active"}`
   reads 0) or the metrics it feeds stopped. One still running that stopped
   erroring after a deploy was fixed.

3. Caddy access: 5xx counts by host and upstream, 4xx spikes, and request
   patterns that look like scanning or credential stuffing against a public
   app.
4. Read raw lines only for the handful of changes that stood out, enough to
   say what the errors are. Before calling a count a jump, run `baseline` on
   the specific line that stood out (`|= "<text>"`), not only the broad
   regex.
5. Before writing, go through your findings and drop any that:
   - matches an entry under Acknowledged issues below. Report it only if it
     recurred or changed after the entry's date, and name the entry.
   - a fleet note in your instructions already explains, such as trex's gaps
     and disk.
   - rests on lines you did not read this run. It goes under Not checked
     instead.

   Name what you dropped, and why, under Checked.

Report up to 8 findings, ranked by how much Kyle should care, in the sweep
layout. The report starts with its bold verdict line: no title, and nothing
before it.
