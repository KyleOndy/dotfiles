# Porting plan: Crucible → Go forge (narrowed)

## Context

The standalone Clojure project at `/home/kyle/src/crucible/forge` (Crucible) has 13 top-level command families. The Go rewrite at `nix/pkgs/forge/` currently covers only the agent orchestration loop (`flux`). After the first pass, we scoped down to the pieces that are still load-bearing.

## What we're porting

### 1. Kind cluster local dev setup (the original `forge` subcommand)

From Crucible's `core/src/forge/` — 27 modules, roughly:

**Lifecycle verbs** (all under `forge lab`)

- `up` — converge to desired state from `forge.yaml` (idempotent)
- `down` — delete clusters, preserve mirrors + volumes
- `nuke` — full teardown (clusters, mirrors, volumes, network)
- `status` — resource state view (forge-owned resources)

**Observability verb** (lives at `forge obs k8s-look`, not under `lab`)

- Works across 1 or many kubeconfigs/contexts in a single invocation.
- Flags:
  - `--kubeconfig <path>` (repeatable) — files to merge. Defaults to `$KUBECONFIG` env (colon-separated list) or `~/.kube/config`.
  - `--context <name>` (repeatable) — select specific contexts from the merged config. Empty = use default list from config file, or current-context if no config.
  - `--all-contexts` — every context in the merged kubeconfig.
  - `--resources <kinds>` — comma-separated, add to watched kinds for this invocation.
  - `--operator <api-group>` (repeatable) — discover CRs for API group(s).
  - `--all` — include system namespaces.
- Output: each row tagged with a `CONTEXT` column when multiple contexts are active; single-context mode suppresses the column.
- Fan-out: per-context fetches run in parallel, aggregated before render.
- Config file (e.g. `~/.config/forge/obs/k8s-look.yaml`):
  ```yaml
  default_contexts: [prod-east, staging, forge-mgmt]
  resources: [pods, deployments, services, ingresses, events]
  operators: [argoproj.io, cert-manager.io]
  ```
- Per-repo override: `$(git toplevel)/.forge/k8s-look.yaml` wins over global config (same shape).

**Building blocks**

- `forge/orchestrator` + `forge/dag` + `forge/dag-plan` — DAG-based parallel provisioning
- `forge/cluster` — Kind cluster lifecycle
- `forge/mirrors` + `forge/mirror-stats` — pull-through registry caches (docker.io, ghcr.io, quay.io, ECR)
- `forge/network` — shared Docker bridge
- `forge/metallb` — load balancer pool config
- `forge/dns` + `forge/cluster-dns` + `forge/coredns` — DNS between host, clusters, mirrors
- `forge/kubeconfig` — per-cluster kubeconfig export
- `forge/components` — ingress-nginx, kube-prometheus-stack
- `forge/discovery` + `forge/reconcile` — find forge-owned resources, clean orphans
- `forge/connectivity` — network validation
- `forge/template` — k8s manifest templating
- Manifests under `manifests/components/` and `manifests/workload/metallb/`

**Rethink candidates during migration**

- Keep all four mirror upstreams, or trim?
- Keep kube-prometheus-stack deployment, or offload to a separate manifest set?

### 2. Ticket + local thinking workflow

Under `forge lab`. Two distinct layers:

**Pre-ticket layer — seeds (top-level `forge seed`, orthogonal to `lab`)**

```
~/work/seeds/<date>-<slug>.md        # e.g. 2026-04-20-coredns-weirdness.md
~/work/seeds/archive/                # pruned + promoted seeds
```

- `forge seed plant --title "…"` — writes a new loose seed. No ticket concept.
- `forge seed garden` — list all loose seeds (date-sorted).
- `forge seed water <id> --context "…"` — append context to an existing seed.
- `forge seed sprout <id>` — create a throwaway git worktree to investigate.
- `forge seed prune <id> [--reason "…"]` — close as dead end; moves to `~/work/seeds/archive/`.
- `forge seed promote <id> [--also <id>,<id>]` — compose a Linear-ready markdown body from the seed(s) and write it to `$EDITOR` (fall through to stdout with `--stdout`). User creates the Linear ticket in the UI, then runs `forge flux linear fetch <ID>`. Seed file is marked promoted (`promoted_at` + `linear_id` frontmatter) and moved to `~/work/seeds/archive/`.

**Post-ticket layer — ticket-scoped artifacts (Linear IDs only)**

```
~/work/tickets/PROJ-456/
  SPEC.md PLAN.md TASKS.md DECISIONS.md LINEAR.md   # flux
  .forge/ tasks/T01-…/                              # flux state
  plans/<ts>-<name>.md                              # `forge lab plan "…"`
  learnings.md                                      # `forge lab learning add …`
  notes.md                                          # free-form (manual)
```

- `forge lab ticket new <LINEAR-ID>` — scaffold ticket dir with empty `notes.md`, `learnings.md`, `plans/` subdir. Does NOT create `.forge/` (that's flux's concern).
- `forge lab ticket list` / `path <id>` — file-system conveniences.
- `forge lab plan "name" [--ticket id]` — timestamped plan file, ticket-scoped. Ticket detected from branch if not passed.
- `forge lab learning add --assumption … --reality … [--ticket id]` — appends to `learnings.md`. Ticket-scoped.

**Flux interplay**

- Flux ignores `seeds/`, `plans/`, `learnings.md`. The Linear ticket body (populated during promotion) is the source of truth once work starts.
- Flux still scaffolds `~/work/tickets/<ID>/` via `flux init` as today. `forge lab ticket new` is a lightweight alternative when you want the ticket dir without the flux state machine.
- Local tickets (`ADHOC-*`) are not supported. Pre-ticket work lives as seeds.

**Promotion flow (the "source of truth" handoff)**

```
forge seed plant --title "coredns drops queries under load"
# ...water over a week...
forge seed promote <id>          # composes Linear-ready markdown in $EDITOR
# user pastes into Linear UI, creates PROJ-789
forge flux linear fetch PROJ-789 # flux pulls the ticket as its starting context
forge flux spec PROJ-789         # flux works from the Linear body only
```

The seed archive preserves the exploration history; the Linear ticket carries the distilled output forward.

## What we're explicitly dropping

- Jira integration (all of `jira/*`, `commands/jira`, `story-creation`, `draft-management`, `sprint-detection`)
- ADF markdown converter (`adf/*`) — only useful with Jira
- Daily log (`daily-log`, `commands/log`, `commands/logging`, `commands/pipe`)
- AI enhancement subsystem (`ai.clj`, OpenRouter / generic gateway)
- `claim` — becomes its own `git-claim` script outside forge
- `config` command
- `doctor` command
- `setup.sh` installer + wrapper-script pattern (Nix flake handles this)
- `completion` command (cobra already generates them for Go forge)

## Proposed Go package layout

```
nix/pkgs/forge/
  cmd/
    flux/              # existing agent pipeline
    lab/               # NEW: local dev + ticket-scoped artifacts
      up.go            #   Kind cluster lifecycle
      down.go
      nuke.go
      status.go
      ticket/          #   new, list, path (Linear IDs only)
      plan.go          #   timestamped plan file (ticket-scoped)
      learning.go      #   add (ticket-scoped)
    seed/              # NEW: top-level, pre-ticket exploration (orthogonal to lab)
      plant.go
      garden.go
      water.go
      sprout.go
      prune.go
      promote.go
    obs/               # NEW: observability umbrella (room to grow)
      k8s-look.go      #   k8s resource inspector (kubeconfig-agnostic, multi-context)
                       #   future siblings: logs, metrics, trace, etc.
  internal/
    cluster/           # Kind lifecycle, mirrors, network, DNS, MetalLB, components
    dag/               # DAG + plan builder (port of forge/dag + forge/dag-plan + forge/orchestrator)
    kubeview/          # k8s-look implementation: multi-kubeconfig fan-out, on-the-fly kinds
    manifest/          # embedded k8s/kustomize manifests (port of manifests/)
    seeds/             # ~/work/seeds/ storage, frontmatter, archive, promotion composer
    workspace/         # ~/work/tickets/<ID>/ path helpers (plan, learning, notes)
  main.go
```

`internal/ticket` and `internal/gitwt` already exist and can be reused.

## Decisions locked in

- **Parallelism**: keep DAG-based parallel cluster provisioning.
- **Config format**: keep YAML, redesign keys as part of the rewrite (don't feel bound to Crucible's schema).
- **`k8s-look` scope**: decoupled from forge-managed clusters. Lives at `forge obs k8s-look`. Takes repeatable `--kubeconfig` / `--context`, works on any cluster. Config at `~/.config/forge/obs/k8s-look.yaml`, per-repo override at `$(git toplevel)/.forge/k8s-look.yaml`.
- **CLI shape**: three new sibling commands next to existing `flux`:
  - `forge lab …` — local Kind clusters + ticket/plan/learning (ticket-scoped artifacts)
  - `forge seed …` — pre-ticket exploration, orthogonal to `lab` (loose seeds, no ticket required)
  - `forge obs …` — observability umbrella, starting with `k8s-look`
- **Seed model**: seeds are loose and pre-ticket (`~/work/seeds/<date>-<slug>.md`). Promotion composes a Linear ticket body; Linear becomes source of truth once work begins.
- **Flux context**: flux phases do not auto-consume seeds/plans/learnings. The Linear ticket body is the handoff point.

## Critical files to port from

- `/home/kyle/src/crucible/forge/core/src/forge/**/*.clj` (27 modules)
- `/home/kyle/src/crucible/forge/core/src/commands/{forge,ticket,plan-cmd,seed,learning}.clj`
- `/home/kyle/src/crucible/forge/core/src/{work,seed,learning}.clj`
- `/home/kyle/src/crucible/forge/core/templates/forge/` (kind-config, metallb-pool, component-ingress, hosts.toml)
- `/home/kyle/src/crucible/forge/manifests/**`
- `/home/kyle/src/crucible/forge/forge.yaml` (config schema reference)
- `/home/kyle/src/crucible/forge/docker/dnsmasq/Dockerfile`

## Suggested port order

1. **`internal/seeds` + `seed plant/garden/water/prune`** — loose file storage, frontmatter handling. Smallest vertical slice.
2. **`seed sprout` + `seed promote`** — sprout reuses `internal/gitwt`. Promote needs a Linear-body markdown composer.
3. **`internal/workspace` + `lab ticket new/list/path` + `lab plan` + `lab learning add`** — ticket-scoped artifacts.
4. **`obs k8s-look`** — multi-kubeconfig fan-out, config + CLI resource kinds. Shakedown for `kubectl` shell-out patterns.
5. **`lab status` + `internal/cluster/discovery`** — read-only forge resource inspection.
6. **`lab up` / `down` / `nuke`** — start with single cluster, no mirrors, then layer in mirrors, MetalLB, DNS, components. Config schema redesign happens here.

## Verification

- Per command family: unit tests for path/file logic; integration tests that shell out to `kind`, `docker`, `kubectl` on a throwaway Docker network.
- End-to-end cluster smoke: `forge lab up` → `forge lab status` → deploy toy workload → `forge obs k8s-look` → `forge lab down` → `forge lab nuke`.
- Seed-to-ticket flow: `forge seed plant …` → `forge seed water …` → `forge seed garden` → `forge seed promote <id>` → paste into Linear → `forge flux linear fetch PROJ-789` → `forge flux spec PROJ-789`.
- Ticket artifacts: `forge lab ticket new PROJ-789` → `forge lab plan "approach"` → `forge lab learning add …` → inspect `~/work/tickets/PROJ-789/`.
- Multi-kubeconfig: `forge obs k8s-look --context prod-east --context staging` — verify `CONTEXT` column and parallel fan-out.

## Open questions

1. **Mirror upstreams** — keep all four (docker.io, ghcr.io, quay.io, ECR), or trim at port time?
2. **Seed promote output** — open in `$EDITOR` by default, with `--stdout` escape hatch?
3. **`lab plan` vs `flux plan`** — `forge flux plan <ticket>` (agentic) vs `forge lab plan "name"` (manual timestamped file). Different umbrellas so no clash — flagging as intentional.
