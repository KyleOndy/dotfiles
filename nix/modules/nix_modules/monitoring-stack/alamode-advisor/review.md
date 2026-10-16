# Monitoring mail review

tiger sends two kinds of mail to kyle@ondy.org, both from `monitoring@ondy.org`:

- **`[alamode-advisor] ...`**: the read-only advisor (`README.md` beside
  this file). One report per alert triage, plus the daily logs and metrics
  sweeps around 06:30.
- **`[FIRING:n] <alertname> (...)` and `[RESOLVED] ...`**: Alertmanager,
  grouped by alertname (`nix/modules/nix_modules/monitoring-stack/alertmanager.nix`).

The advisor is wrong often enough that a report is a lead, not a verdict.
Every finding gets checked against primary data before it reaches Kyle.
Reviewed mail gets archived, so the inbox holds only what is unreviewed.

Nothing changes on a host, in the repo or in the mailbox until Kyle says go.
Verification is read-only: GET requests, file reads, `journalctl`, `zfs list`.
No restarts, no POST, PUT or DELETE to any API, no `zfs set` or `destroy`, no
\*arr queue actions.

Mail lives on trex only. Run from the worktree root; scratch files go in
`$TMPDIR`.

## 1. Sync and list

```bash
timeout 300 notmuch new    # preNew runs mbsync, one channel at a time
q='tag:inbox and from:monitoring@ondy.org'
notmuch search --sort=oldest-first "$q"
notmuch search --format=json --output=summary "$q" > "$TMPDIR/monitor-review.json"
notmuch search --output=messages "$q" > "$TMPDIR/monitor-review.ids"
```

An argument such as `24h` or `2026-10-14..` adds `and date:<range>` to `q`.
The ids file is the reviewed set: step 5 archives exactly those, never mail
that landed mid-review. If `notmuch new` fails, mbsync did: say so and review
what is local.

## 2. Read, and gather context

Save the text of each mail under `$TMPDIR/monitor-review/`, where subagents
can read it.

An advisor mail is a report from `/var/lib/alamode-advisor/reports/` on tiger,
named `<utc>-<kind>-<name>.md`, and its subject is the report's first line.
Copy the Markdown from there rather than decoding the mail:

```bash
jq -r '.[].subject' "$TMPDIR/monitor-review.json" |
  sed -n 's/^\[alamode-advisor\] //p' |
  ssh tiger 'cd /var/lib/alamode-advisor/reports &&
    while IFS= read -r s; do printf "%s: " "$s"; grep -lxF "# $s" -- *.md | tr "\n" " "; echo; done'
```

A triage title such as `UnifiWanLatencyHigh on tiger` repeats with every
triage of that alert, so take the file whose timestamp falls just before the
mail's date. If tiger is unreachable, the mail's text part is the same
Markdown:
`notmuch show --format=text --entire-thread=false --include-html=false --body=true id:<id>`.

Alertmanager keeps no copy, and its mail is HTML only:

```bash
notmuch show --format=raw --part=2 id:<id> | textutil -stdin -format html -convert txt -stdout
```

Collapse repeated FIRING mails for one alert and host into one item: first and
last sent, whether it resolved, and whether an advisor triage covers it.

Every verdict needs this context:

```bash
ssh tiger 'cat /var/lib/alamode-advisor-acks/acknowledged.md'
ssh tiger 'curl -s http://127.0.0.1:9093/api/v2/alerts | jq -r ".[] | [.labels.alertname, .labels.host, .status.state, .startsAt] | @tsv"'
ssh tiger 'curl -s http://127.0.0.1:9093/api/v2/silences | jq -r ".[] | select(.status.state==\"active\") | [.endsAt, .comment] | @tsv"'
ssh tiger 'nixos-version --configuration-revision; ls -lt --time-style=+%FT%T /nix/var/nix/profiles | head -8'
```

A deploy restarts units, so line restarts and units gone quiet up against each
host's generation times. If tiger runs a commit that is not on main
(`git merge-base --is-ancestor <rev> main`), say so: the next deploy from main
undoes it.

## 3. Verify every finding

List every finding (a sweep holds several, a triage usually one) and settle
each from primary data: rerun the query against VictoriaMetrics or Loki, read
the journal, ssh to the host, read the repo. A number in a report is the claim,
not the evidence. The monitoring skill has the query endpoints.

Each of these has fooled the advisor before, so check them first:

- **"New", "spike", "tripled"**: compare against the 14-day range, not one
  earlier day. One low day makes a normal one read as a jump.
- **"No rule covers this"**: grep `vmalert.nix`, and check whether the alert
  fired.
- **Direction**: confirm the metric moved the way the report says.
- **Memory on ZFS hosts**: the ARC (`node_zfs_arc_size`) shrinks on demand, so
  it counts as available.
- **Log counts**: an error regex can match a unit description or a file name.
  Read a sample of the lines.
- **Joins**: a client address or user comes from the same log line, never
  paired from a second query. Navidrome logs every client as 127.0.0.1.
- **Contradictions**: two reports often give different numbers or causes for
  one thing. Settle it with data and say which was right.
- **Already acknowledged**: a finding an entry covers is an advisor bug, not a
  finding. Name the entry.
- **Repeat triages**: one ongoing alert triaged again after a deploy or a flap.

Each verdict is one of: confirmed, partly (right symptom, wrong cause or
size), wrong, cleared (true then, gone now), or unverified (say why). A claim
about upstream behavior gets a link pinned to a version or commit; search the
web when a finding rests on upstream behavior or a known bug.

With more than about five findings, or findings in unrelated subsystems, split
them by subsystem (storage and the \*arr stack, network and UniFi, hosts and
deploys, the advisor itself) and run one subagent each, in parallel. Give each
the saved mail paths, the acknowledgements, the read-only rules above and the
findings it owns. Ask for, per finding, the verdict, the evidence (command plus
1-3 lines of output) and any proposed change as `path:line`, in at most 70
lines.

## 4. Report

Lead with the counts: "13 findings across 4 mails: 6 confirmed, 3 partly, 4
wrong. Nothing changed yet."

Then these sections, numbered straight through so Kyle can answer "do 1-4 and
7". Leave out an empty one.

1. **Do**: fixes that need no decision. Each names the change (`path:line`, or
   the command) and why.
2. **Needs you**: decisions, spot checks, and what only Kyle can do (the UniFi
   UI, a household call, hardware). Each with a recommendation.
3. **Watch**: real, nothing to do yet. What to re-check, and when.
4. **Wrong or cleared**: one line each, with the evidence that settled it.
5. **Acknowledgements**: drafted entries, for anything true and expected that
   tomorrow's sweep would report again.
6. **Advisor**: this batch's wrong findings grouped by cause, each with the
   change to `alamode-advisor/system.md`, a `sweep-*.md` or `tools.ts` that
   would stop it.

A firing alert with nothing to do still gets a line: why it fires, when it
clears, and whether a silence fits. Questions go last, one line each. Then
stop and wait.

## 5. On go

Do only the items Kyle approved.

**Repo changes**: one commit per fix. Verify with the command in
`.pi/verify.json`. Kyle deploys, so never deploy unless asked.

**Acknowledgements**: kyle owns the file, so no sudo. Keep the day's first
backup, make sure the file ends in a newline, then append:

```bash
ssh tiger 'f=/var/lib/alamode-advisor-acks/acknowledged.md
cp -pn "$f" "$f.$(date +%F).bak"
[ -z "$(tail -c1 "$f")" ] || echo >> "$f"
cat >> "$f"' <<'EOF'
- 2026-10-16: <the thing, its dates, what is known>. Report <what would be new>.
EOF
```

An entry covers one event, not a category: name the thing, the dates and what
is known. Add `until YYYY-MM-DD` to a "known, fixing later" entry. The advisor
reads only the first 20,000 characters, so offer to prune entries past their
`until` or no longer true.

**Silences**: `silence-host <host> "<duration>" "<reason>"` for a whole host.
For one alert:

```bash
ssh tiger 'bash -s' <<'EOF'
jq -n --arg end "$(date -u -d '+3 days' +%FT%TZ)" '{
  matchers: [
    {name: "alertname", value: "<alertname>", isRegex: false, isEqual: true},
    {name: "host", value: "<host>", isRegex: false, isEqual: true}
  ],
  startsAt: (now | todate), endsAt: $end, createdBy: "kyle",
  comment: "<why, and what clears it>"
}' | curl -sf -X POST -H 'Content-Type: application/json' -d @- http://127.0.0.1:9093/api/v2/silences
EOF
```

**Archive**: offer it once the approved items are done. The move happens on
the server, because mbsync expunges only the local side
(`nix/modules/hm_modules/terminal/email.nix`), so a local move never leaves
the server's INBOX:

```bash
a=nix/modules/nix_modules/monitoring-stack/alamode-advisor/archive-mail.py
python3 -I "$a" < "$TMPDIR/monitor-review.ids"           # lists matches
python3 -I "$a" --move < "$TMPDIR/monitor-review.ids"
timeout 300 notmuch new
notmuch count 'tag:inbox and from:monitoring@ondy.org'
```
