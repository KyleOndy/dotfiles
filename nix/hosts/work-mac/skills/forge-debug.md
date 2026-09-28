---
name: forge-debug
description: Introspect a forge instance that looks broken, stuck or slow (lima VM, kind clusters, the shared pull-through cache, ArgoCD), including ones a pi coordinator agent owns. Use when forge up hangs or fails, an agent sits in starting-forge, a cluster is missing, or someone asks what a forge instance is doing.
---

# Debugging a forge instance

Read-only first. `forge down`, `forge nuke` and `forge resize` destroy the
state you are trying to read, so ask before running any of them.

Work outside pi's sandbox: `forge ls` and `limactl` need `~/.lima`, which it
denies.

## 1. Find the instance and its phase

```bash
forge ls
```

One row per VM: `-` is the unnamed `forge`, `<n>` is `forge-<n>`, `cache` is
`forge-cache`.

- PHASE `up`, `down`, `nuke`, `resize`: that forge command is running now.
- `ready`: every declared cluster has all its nodes running, or for the
  cache, all three mirrors answer.
- `partial` or `empty`: VM up, some or no clusters. Nothing is converging it.
- STATE `Broken` or a VM missing from the list entirely: see step 5.
- OWNER `<coordinator>/<agent>`: pi-broker holds the instance for that agent.

Then, for the one instance:

```bash
FORGE_INSTANCE=<n> forge status   # omit FORGE_INSTANCE for the unnamed one
```

## 2. Find the log for where it stopped

A coordinator's agent logs to `~/.local/state/pi-coord/<coordinator>/`:

| File                      | Holds                                                                |
| ------------------------- | -------------------------------------------------------------------- |
| `logs/<agent>.forge.log`  | full `forge up` output; the last `>>>` line is the stuck step        |
| `logs/<agent>.broker.log` | worktree creation, tmux window                                       |
| `state/<agent>.json`      | `state` (`creating`, `starting-forge`, `running`, `failed`), `error` |
| `broker.log`              | every request the coordinator made and its answer                    |

For a hand-run `forge up`, the terminal is the log.

pi-broker runs `forge nuke` when `forge up` fails, so a `failed` agent has no
VM left. Everything to know about it is in `<agent>.forge.log`.

## 3. Look inside it

```bash
n=<n>; vm=forge-$n                         # vm=forge for the unnamed one
export DOCKER_HOST=unix://$HOME/.lima/$vm/sock/docker.sock
export KUBECONFIG=$HOME/.local/state/forge/$n/kubeconfig.yaml

docker ps -a                               # kind nodes, with state
docker images                              # has kindest/node landed yet
kubectl config get-contexts
kubectl --context kind-forge-mgmt get pods,jobs -A
kubectl --context kind-forge-mgmt -n argocd describe pod <pod>
limactl shell --workdir / $vm -- sh -c 'uptime; free -m; df -h /'
```

The cache is its own VM, `forge-cache`, one `registry:2` per upstream:

```bash
forge ls | grep cache                      # PHASE ready: all three answer
export DOCKER_HOST=unix://$HOME/.lima/forge-cache/sock/docker.sock
docker logs --tail 50 mirror-quay.io       # a mirror's upstream errors
curl -s http://127.0.0.1:6420/v2/_catalog  # what docker.io has cached
```

The unnamed instance's kubeconfig is the `kubeconfig` in
`~/.config/forge/forge.yaml`, which `forge status` prints.

## 4. Match the stuck step

| Last `>>>` line or error                                                            | Usual cause and check                                                                                                                                                                |
| ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `Ensuring VM`, then nothing                                                         | Boot, or the docker probe never passing. `limactl list`, then `~/.lima/$vm/ha.stderr.log` and `serialv.log`. forge gives up at 10m.                                                  |
| `Creating management cluster` / `workload cluster`                                  | Pull of `kindest/node`, slow only when the cache has not seen it. `docker images` shows when it lands; a VM older than the dockerd mirror pulls it directly (drift warning).         |
| `Installing ArgoCD`, then `failed pre-install: timed out waiting for the condition` | A chart hook Job did not finish inside helm's 5m. `get pods,jobs -n argocd` names it; `describe pod` shows ImagePullBackOff or Pending. Check the cache mirror's logs and `free -m`. |
| `Installing ArgoCD`, chart fetch error                                              | `argoproj.github.io` or `release-assets.githubusercontent.com` unreachable. `FORGE_ARGOCD_CHART` points at a local chart instead.                                                    |
| `ERROR: no docker daemon at ...`                                                    | VM stopped or its socket gone. `limactl list`.                                                                                                                                       |
| `[warn] VM '<vm>' is not running ...`                                               | Drift from `vm.nix`. Harmless until the change matters; `forge nuke && forge up` rolls it forward.                                                                                   |

Memory: a small VM has 4GiB for two kind nodes and ArgoCD.
`free -m` showing under ~300MB available points at size, not a bug.

## 5. VM missing or Broken

- Missing, with an agent whose `state/<agent>.json` reads `failed`: pi-broker
  nuked it after a failed `up` and released the slot, so `forge ls` no
  longer shows an OWNER. Read the agent's `forge.log`.
- `Broken`: `limactl list --json $vm`, then `~/.lima/$vm/ha.stderr.log`.
- A slot in `~/.local/state/pi-coord/slots/<n>/` with no VM behind it is
  reclaimed by the next spawn once its agent is not starting. Do not delete
  it by hand while a coordinator is running.

## Reporting back

State the instance, the phase, the last `>>>` step, the error line verbatim,
and which of the checks above you ran and what they showed. Propose the fix;
do not rebuild or nuke without asking.
