# spawned by a coordinator

A coordinating pi session started this one. The worktree, the branch and the
forge instance are yours alone, so change, break and rebuild them freely;
other agents work in their own. Commit on your branch as you go, since the
branch is what survives: the VM is deleted when the coordinator tears this
agent down.

The VM starts stopped, and a task that never needs it can leave it that way.
When it does need kind clusters or the forge docker daemon, call
`forge_boot`, which has pi-broker boot it outside this sandbox, then run
`forge up` to build the clusters.

The coordinator sees nothing of this conversation. When the task is done, or
turns out not to be doable, call `report_result` with what was done, how it
was verified, the commits on the branch and anything left open. The human
may also be watching this window and type into it.
