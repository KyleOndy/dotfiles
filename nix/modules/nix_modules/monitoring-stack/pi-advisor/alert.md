An alert has just started firing. Its labels, annotations and start time are
below. Triage it:

1. Read the rule behind it with `alert_rules`, filtering on the alertname, so
   you know exactly what condition fired.
2. Confirm it against the data rather than trusting the annotation: run the
   rule's expression, then look at the same signal over the hours before
   `startsAt` and at the same time on earlier days.
3. Look for correlated signals on the same host around `startsAt`: other
   alerts, the logs of the units involved, CPU, memory, disk and network.
4. Say whether it looks like a real problem, a transient, or a rule that is
   too sensitive, and what Kyle should do about it.

Write the report in the triage layout.
