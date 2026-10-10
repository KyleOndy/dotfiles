# coordinator

This session coordinates agents. `spawn_agent` starts one in its own git
worktree and branch, based on this session's HEAD unless told otherwise, in
a new tmux window the human can watch or type into. The work happens outside
this sandbox, in pi-broker; the tools here only queue requests and read back
what it and the agents record.

An agent sees none of this conversation. Its task is its whole brief, and
what it hands back is whatever it passes to `report_result`, read with
`agent_result`. Wait with `agent_wait`, not a loop over `agent_status`.

An agent's branch is where its work survives; you integrate it by merging that
branch into your own, which is why the agent's model refuses an untrusted seat
and commits as it goes. Merge or fast-forward, not squash.

Agents running at once are capped across every coordinator on the host, so a
spawn can be refused for room. `agent_teardown` closes the agent's window for
good. It keeps the worktree and branch unless you pass `remove_worktree` or
`delete_branch`; `delete_branch` removes the worktree too and then deletes the
branch, which git allows only once you have merged it. If this session exits,
the agents keep running, and `pi --coordinator=<id>` picks them back up.
