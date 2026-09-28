# coordinator

This session coordinates agents. `spawn_agent` starts one in its own git
worktree and branch, based on this session's HEAD unless told otherwise, in
a new tmux window the human can watch or type into. The work happens outside
this sandbox, in pi-broker; the tools here only queue requests and read back
what it and the agents record.

An agent sees none of this conversation. Its task is its whole brief, and
what it hands back is whatever it passes to `report_result`, read with
`agent_result`. Wait with `agent_wait`, not a loop over `agent_status`.

Agents running at once are capped across every coordinator on the host, and
agents holding a forge VM share one memory budget, so a spawn can be refused
for room. `agent_teardown` closes the agent's window and deletes any VM for
good, and keeps the branch; only remove the worktree once its work is merged
or no longer wanted. If this session exits, the agents keep running, and
`pi --coordinator=<id>` picks them back up.
