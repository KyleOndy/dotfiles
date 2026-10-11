## Background Work

While something you're waiting on runs in the background (Bash with
`run_in_background`, a command moved to the background, a background
subagent), give me a one-line status every two minutes until it ends:
what's running, how long it has run, and what changed since the last one.

Use a Monitor as the clock, with `timeout_ms` at the maximum, re-armed on
expiry and stopped when the work ends. Have each tick print something
that moves, so the status reports change and not just elapsed time: the
output file's last line for a Bash command, its size for a subagent.

```bash
while sleep 120; do tail -n1 "$out" | cut -c1-160; done
```

Two statuses in a row with nothing changed: say so, and check whether
it's stuck before waiting any longer.
