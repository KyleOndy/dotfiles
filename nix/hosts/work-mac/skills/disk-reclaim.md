---
name: disk-reclaim
description: Free disk space on the work mac. Runs disk-reclaim quick for the free drops, then works through what needs judgment (merged worktrees, ticket repo clones, old alamode sessions, tart and lima VMs) and asks before each deletion. Use when the disk is full or low, or when asked what is using space.
---

# Reclaiming disk on work-mac

## 1. Free drops, then the survey

Below about 20G free, run `disk-reclaim quick` first. It deletes only what a
rebuild or re-download restores: the Go build cache, golangci-lint and uv
caches, colima's downloaded base images, orphaned envtest servers and their
`$TMPDIR/k8s_test_framework_*` dirs, alamode gcroots outside the current
deployment, then a user `nix-collect-garbage`.

Then `disk-reclaim report`, which changes nothing. Do the areas below
largest first. `du` counts every APFS clone in full, so a worktree or VM
cloned from another frees less than it reads: 13 infra worktrees reading
12G freed 1.8G. Read `df -k /System/Volumes/Data` before and after each
step and report the freed size `df` shows.

Everything past step 1 asks first: list what goes, its size and why it is
safe, then wait for a yes.

## 2. Worktrees with a deleted upstream branch

The report's list is as of the last fetch. Fetch first:
`git -C ~/src/modularml/<repo>/main fetch --prune origin`.

A worktree can go when its PR is merged and it has no local changes:

```bash
gh pr list --repo modularml/<repo> --head <upstream branch> --state all --json number,state
git -C <worktree> status --porcelain
```

Remove with `git worktree remove <path>`, never `--force`, then `rmdir` the
ticket directory above it if it is empty. A closed-unmerged PR, uncommitted
or untracked files, or no PR at all: list them for Kyle, do not remove.
Envtest leaves read-only files under `operator/bin`, so `git worktree
remove` can unregister the worktree and still leave the directory behind;
`chmod -R u+w` it, then `rm -rf`.

## 3. Ticket repo clones

`~/work/tickets/*/repos/<org>/<repo>` is gitignored as re-cloneable
upstream source. Keep the rest of the ticket directory: notes, drafts and
data are the record. A clone can go unless it holds work of its own:

```bash
git -C <clone> log --oneline --branches --not --remotes   # unpushed commits
git -C <clone> stash list
git -C <clone> status --porcelain | grep -v '^??' | cut -c1-2 | sort | uniq -c
```

A status of only ` D` lines is a checkout cut short, often by a full disk,
and holds nothing. `pr-<n>` branches are fetched PR heads, already on
GitHub. A branch of Kyle's own that `git ls-remote origin` does not list
stays.

## 4. Orphaned worktree dirs

A dir whose `.git` file names a missing gitdir. Its `.direnv` still roots
nix store paths, and git cannot show its uncommitted work, so show Kyle the
newest files in it before suggesting `rm -rf`. A nix gc after removing it
frees what it rooted.

## 5. alamode sessions

`~/.local/state/alamode/workspaces/<id>` holds a session's transcript and
private git storage (`<id>/.bare`); `records/<id>` is its audit trail.
alamode has no delete command, and `alamode sessions peek` refuses most old
sessions ("workspace root was replaced", coordinator children). Check the
storage directly instead, with the source from `alamode sessions` (JSON
lines, `.id` and `.source`):

- every tip from `git -C <id>/.bare for-each-ref refs/heads refs/tags`
  passes `git -C <source> cat-file -e <sha>^{commit}`, and
- `git -C <id>/worktree status --porcelain` is empty.

Either one failing still allows two cases. A tip whose subject is "Snapshot
authorized working files for Pi" is alamode's launch snapshot, with no
agent commit after it. A `~/work` tip from before 2026-10-27 may live in
`~/.local/state/work-prerewrite-2026-10-27.git` instead, from that day's
history rewrite. Anything else stays. Keep records unless Kyle says
otherwise.

## 6. VMs

- `~/.local/share/alamode-builder/tart`: `builder.json`'s `base_vm` is the
  one in use; its `tart` is the binary to run, under
  `TART_HOME=~/.local/share/alamode-builder/tart`. Any other VM, and
  `tart/cache` (`tart prune --entries caches`), matter only for
  re-provisioning. They share blocks with `base_vm`: a base VM and an OCI
  cache that `du` put at 62G freed 2.5G.
- `~/.lima/forge-*`: through forge's own commands only; see the forge-debug
  skill. Never `limactl delete` an instance a coordinator agent leases.
- `~/.colima`: `docker image prune -a` frees space inside the VM, not on the
  host. The host file shrinks only when the VM is recreated.

## 7. Needs Kyle

- Old nix system generations need sudo. `make cleanup` drops only those
  older than 7 days; all but the current one is
  `! sudo nix-env -p /nix/var/nix/profiles/system --delete-generations old`,
  then `disk-reclaim quick` for the gc.
- Spotify: leave it alone.
