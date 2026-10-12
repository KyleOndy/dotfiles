An alert has just started firing. The JSON below lists its labels,
annotations and start time. More than one entry means one rule fired for
several series on one host in the same evaluation, such as several
calendars: triage them together, and say so if they turn out to have
different causes.

Triage it:

1. Read the rule behind it with `alert_rules`, filtering on the alertname, so
   you know exactly what condition fired.
2. Confirm it against the data rather than trusting the annotation: run the
   rule's expression, then look at the same signal over the hours before
   `startsAt` and at the same time on earlier days.
3. Look for correlated signals on the same host around `startsAt`: other
   alerts, the logs of the units involved, CPU, memory, disk and network.
4. Say whether it looks like a real problem, a transient, or a rule that is
   too sensitive, and what Kyle should do about it. An entry under
   Acknowledged issues below that matches is context for that, not a reason
   to skip the triage.

Write the report in the triage layout. The report starts with its bold
verdict line: no title, and nothing before it.
