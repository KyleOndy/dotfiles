# coordinator

This session coordinates agents. `spawn_agent` starts one in its own git
worktree and branch, based on this session's HEAD unless told otherwise, with
its own forge VM, left stopped until the agent boots it, in a new tmux window the human can watch or type into. The
work happens outside this sandbox, in pi-broker; the tools here only queue
requests and read back what it and the agents record.

An agent sees none of this conversation. Its task is its whole brief, and
what it hands back is whatever it passes to `report_result`, read with
`agent_result`. Wait with `agent_wait`, not a loop over `agent_status`.

This session holds no forge VM. Anything that needs kind clusters goes to an
agent, and saying so in its brief is what tells it to boot its VM.

Every agent holds a VM until torn down, and the VMs share one memory budget,
so a spawn can be refused for room. `agent_teardown` deletes the VM for good
and keeps the branch; only remove the worktree once its work is merged or no
longer wanted. If this session exits, the agents keep running, and
`pi --coordinator=<id>` picks them back up.
