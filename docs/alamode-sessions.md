# alamode sessions on Darwin

Start in a repository with `alamode`, or use `alamode coord` to manage durable
agents from the main conversation. A launch snapshots the repository into
private Git storage, where the session commits, and quitting
[lands](#landing) those commits back in the repository. Outside Git, alamode
starts with an empty private workspace.

`alamode` wraps the upstream pi coding agent: pi is the engine, alamode is
the product. Flags after `--` reach the engine verbatim; alamode's own flags
never follow it.

## Grants

Choose grants when creating a session:

```sh
alamode --allow-kagi --allow-node --listen 3000
alamode coord --profile work
alamode coord --allow-nix
```

`--web` permits public web destinations. `--allow HOST` adds one destination.
`--allow-read PATH` grants host reads; `--allow-rw PATH` grants reads and
writes. Use private `$TMPDIR` for scratch files. Broad writes overlapping
trusted service sockets or session records are rejected.

`--listen PORT` admits one loopback listener and connections to that port.
It also authorizes any existing host service on that port; choose deliberately.
Provider and Kagi credentials stay in host relays. Workloads receive scoped
tokens. The host model catalog must explicitly list each permitted model.

`--profile NAME` applies a grant preset defined by the host's
`hmFoundry.dev.alamode.sandbox.profiles`; it expands into the same fields
the flags set and merges with any flags given alongside it.

`--allow-nix` needs one of two things in the alamode Home Manager module.
With `sandbox.builderConfig` and a provisioned
[Darwin builder](../nix/pkgs/alamode-builder/README.md), `nix build` and
`nix eval` snapshot dirty files, submit them to that service, and preserve
stdout, stderr and exit status. Outputs stay in the retained VM. With
`sandbox.nixDaemon`, the session gets a nix client for a second daemon whose
builds are all offline, and outputs land in the host store
([alamode-host-nix.md](alamode-host-nix.md)). Every start runs canary builds
through it first and refuses nix if one would reach the network. The host
daemon socket is never granted.

## Landing

The happy path is a worktree per task: `alamode slice NAME` makes one off the
base branch and starts `alamode` in it, in a new window of the worktree's tmux
session. When the session quits, edits left uncommitted become a `wip:
uncommitted at exit` commit, and the wrapper fetches the session's commits
into the repository it started from through the same admission as export:

- The branch checked out at launch fast-forwards to them when the launch was
  clean, the checkout is still on that branch, git can fast-forward it, and
  no agent context file such as `AGENTS.md`, `CLAUDE.md` or anything under
  `.claude/` changed.
- Anything else waits on a new branch, `alamode-ID`, and the launch branch
  is NOT moved. After a launch with uncommitted changes, the adopt command
  leaves out the commit holding them.

pi says which of the two to expect as it starts, so a launch from
uncommitted changes or a detached HEAD is flagged before the work rather
than at quit.

Every outcome ends with what happened and the commands for what comes
next:

```text
alamode: 2 commits are waiting on alamode-20261013-102233-ab12cd34.
alamode: main was NOT moved.
alamode: These commits change files your agents read as instructions:
alamode:     AGENTS.md
alamode: pi and Claude outside the sandbox load these without asking, so read
alamode: them as model-written before taking them.
alamode:
alamode:   review   git log -p 67e33ed81ca3..alamode-20261013-102233-ab12cd34
alamode:   adopt    git merge --ff-only alamode-20261013-102233-ab12cd34 && git adopt 67e33ed81ca3
alamode:   discard  git branch -D alamode-20261013-102233-ab12cd34
```

A fast-forward offers `review`, `adopt` (`git adopt` signs the commits) and
`undo`. When the last commit is the `wip: uncommitted at exit` one, `unwip`
turns it back into staged changes. Landing creates no other branch and moves
no other one. Coordinator children land only through their coordinator. If
landing fails, the commits stay in the session and `alamode sessions export
ID` still works. `git adopt` in turn ends with the push, merge and worktree
cleanup commands for the branch it signed.

## Resume and results

```sh
alamode resume              # the most recent session
alamode resume ID
alamode resume ID GRANTS    # the same session with GRANTS in place of its own
alamode sessions            # list retained sessions
alamode sessions show ID    # a session's recorded authority
alamode sessions export ID  # a verified review bundle
```

Resume restores the recorded grants and workspace. To change the grants
of work already under way, regrant it: `/regrant` inside pi, or
`alamode resume ID GRANTS` after quitting. GRANTS replace the session's
own, as on a launch, so restate every grant to keep; quitting prints the
command with the current flags filled in, and `/regrant` opens an editor
on them. `/regrant` quits pi and asks y/N at the terminal before the new
grants apply, since the session can write the request it leaves; a no
ends the session like a normal quit. Either way the same transcript and
worktree continue, pi's header shows what changed, and `sessions show`
lists each earlier policy under `regrants`. `--local`, `--local-model`
and `--no-PROVIDER` stay as launched, and a coordinator and its agents
keep their grants. A rebuild between launches moves a resumed session to
the new build only on a yes at the terminal: the new build derives the
grants again from the recorded flags (or the GRANTS given), the prompt
shows both builds, what changed and the reasons to answer no, and the new
`regrants` entry keeps the old build's configuration. A coordinator stays
on the build that recorded it, and the error names that build and the
export command that still works. Provider credentials may rotate.

Export requires committed changes and a stopped session. It is data-only:
the session's private Git storage is sealed host-side through the same
admission that reviews every proposal, nothing in the session executes,
and no runtime build is consulted, so a rebuild between launches cannot
strand committed work. It prints a verified, standalone bundle and ref as
JSON on stdout, and the commands to fetch, review and adopt it on stderr.
Review that bundle before integrating it into the human repository. Export
never changes the human branch.

## The coordinator

```sh
alamode coord            # start a coordinator for this repo
alamode coord ls         # every coordinator, live or stopped, with agents
alamode coord attach ID  # reconnect; also revives a stopped daemon
alamode coord stop ID    # stop the daemon; agents keep running
alamode coord start      # print headless JSON credentials and exit
```

The coordinator's tools handle questions, steering, interruption, follow-up,
result inspection and child integration. The rows above the editor show each
agent's state and, while it executes, the tool it last started. Those tool
names and targets are the agent's text, so they stay on the human's screen
and never reach the coordinator's model. Closing the UI leaves agents
running; `coord ls` finds them and `coord attach` reconnects. Stopping the
daemon preserves every agent and its work; a later attach restarts it from
its recorded configuration. A lost agent requires explicit resume;
interrupted work is not replayed automatically.

`alamode-delegate` (or `alamode delegate`) uses the same coordinator service;
`alamode-delegate --help` lists its actions. Headless consumers consume
`coord start`'s JSON credentials.

Run the [regression suite](alamode-sandbox-tests.md) after runtime or policy
changes.
