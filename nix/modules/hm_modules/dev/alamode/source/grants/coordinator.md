# coordinator

`spawn_agent` starts a sandboxed alamode session with its own repository and
branch. Give it a complete brief; it cannot read this conversation.
Children inherit this session's grants and cannot widen them. Forge is
optional and requires the human's `--allow-forge` grant.

Children start from this session's recorded snapshot. Set `include_commits`
to include the current committed HEAD; the worktree must be clean.
`agent_integrate` admits a child's exported commits and cherry-picks them
inside this session. The human's original checkout stays untouched.

Use `agent_wait` for completion, `agent_result` for the outcome, and
`agent_send` to steer or follow up. `agent_answer` resolves a pending dialog.
`report_result` is the child's account of its work; successful verification
requires evidence from the checks it ran.

Active work and retained worker processes have separate host-wide caps.
`agent_interrupt` cancels the turn and queued messages. `agent_teardown`
closes the worker while preserving its session, repository and branch.
`agent_resume` reopens preserved work without replaying the last task.

Children survive the main TUI exiting. `alamode coord attach <id>` reconnects
the original main session. Use `/agents` and `/agent` to inspect and drive
children from the stock TUI. No separate child terminal is required.
