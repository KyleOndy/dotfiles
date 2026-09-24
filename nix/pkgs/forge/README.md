# Forge

Packaged as `pkgs.forge`; config is read from `$XDG_CONFIG_HOME/forge/forge.yaml`,
which work-mac populates from `forge.yaml` beside this README. `FORGE_CONFIG`
overrides the path.

## Purpose

Forge provisions and manages a local multi-cluster Kubernetes environment for
testing ArgoCD-based GitOps workflows. It handles **layer 1** infrastructure:
Docker networking, a shared pull-through registry cache, Kind clusters, ArgoCD
installation, and cross-cluster registration.

It does **not** manage **layer 2** concerns: application deployments, ArgoCD
Applications/ApplicationSets, or any workload configuration. That is the
responsibility of the GitOps layer running on top.

---

## Architecture

```
lima VM: forge (NixOS, no host mounts)
└── dockerd
    └── network: forge
        │
        ├── forge-mgmt              (Kind, management cluster)
        │   ├── forge-mgmt-control-plane
        │   └── ArgoCD (argocd namespace)
        │       ├── registered: forge-1  → https://forge-1-control-plane:6443
        │       └── registered: forge-2  → https://forge-2-control-plane:6443
        │
        ├── forge-1                 (Kind, workload cluster)
        │   ├── forge-1-control-plane
        │   └── forge-1-worker
        │
        └── forge-2                 (Kind, workload cluster)
            ├── forge-2-control-plane
            └── forge-2-worker
```

All containers share the `forge` Docker bridge network. Inter-container
communication uses Docker DNS (container names resolve to IPs).

## Docker host

Everything above runs in a lima VM that `forge up` creates, defined by
`vm.nix` and built from `guest.nix`. `forge` exports
`DOCKER_HOST=unix://${LIMA_HOME:-~/.lima}/forge/sock/docker.sock` for itself
and every docker and kind call it makes, replacing whatever was set.

A kind node runs systemd, so it needs a privileged container, and a privileged
container is root on whatever the VM can see. That makes the VM the boundary
rather than the daemon, so it mounts no host path and forwards only the API
port window plus the docker socket. The window is `6440-6455` on 127.0.0.1: the
management cluster takes 6440 and workload clusters take 6441 up, in
`clusters:` order. forge refuses a config with more than 16 clusters in total.
Everything else is denied, which is why a cluster's ingress is not reachable
from the host.

`forge up` warns when the instance's own copy of its config
(`~/.lima/forge/lima.yaml`) differs from what `vm.nix` builds, at whatever
CPUs and memory the instance holds. Any edit to
`vm.nix` or `guest.nix` does that, and so does a hand edit of the instance.
Rolling it forward means `forge nuke && forge up`, since a VM cannot be
reconfigured without deleting the clusters inside it.

The flake check `forge-vm` (`nix/checks/forge-vm.nix`) holds that boundary: no
mounts, a docker socket forward, the API window on both address families, a
deny-all pair at the end of `portForwards`, and a script that creates its VM
from the same config. It asserts the same on a named instance's rendered
config.

## Instances and sizes

`FORGE_INSTANCE=<n>` (1-15) selects one of several VMs that run side by side,
which is how pi's coordinator gives each agent its own
(`nix/pkgs/pi-broker`). Unset is the instance described above.

|               | unset                              | `FORGE_INSTANCE=n`                                                           |
| ------------- | ---------------------------------- | ---------------------------------------------------------------------------- |
| VM            | `forge`                            | `forge-<n>`                                                                  |
| API ports     | `6440-6455`                        | `6440+16n` to `6455+16n`                                                     |
| kubeconfig    | `FORGE_KUBECONFIG` or `kubeconfig` | `~/.local/state/forge/<n>/kubeconfig.yaml`                                   |
| config        | `FORGE_CONFIG` or `forge.yaml`     | `FORGE_CONFIG`, else the copy `up` last saved in `~/.local/state/forge/<n>/` |
| new VM's size | large                              | small                                                                        |

Each instance's lima config is `vm.nix`'s with its own port window, CPUs and
memory, rendered at creation (`forge vm-config` prints it). Two sizes:
small is 2 CPUs and 4GiB, large 4 CPUs and 8GiB. `forge up --size S` picks one
for a new VM and refuses a mismatch on an existing one; `forge resize S` stops
the VM, edits its CPUs and memory, and starts it again. `forge-small.yaml`
declares the management cluster and one single-node workload cluster, which is
what pi-broker brings a small instance up with.

A named instance's directory is the only path pi's `--allow-forge=<n>`
grants besides the socket. From inside that sandbox `forge down` and
`forge up` work against the instance; creating or deleting the VM does not,
since lima's instance directory is not granted.

---

## Pull-Through Cache

Every instance pulls through one more lima VM, `forge-cache`, so an image
comes from the internet once per host rather than once per VM, and outlives
`forge nuke --all`. It is the same template as the instances (no mounts, a
deny-all tail), at 2 CPUs, 2GiB and a sparse 100GiB disk, and runs one
`registry:2` pull-through mirror per upstream:

| Container          | Upstream                       | Port   |
| ------------------ | ------------------------------ | ------ |
| `mirror-docker.io` | `https://registry-1.docker.io` | `6420` |
| `mirror-ghcr.io`   | `https://ghcr.io`              | `6421` |
| `mirror-quay.io`   | `https://quay.io`              | `6422` |

Its config forwards `6420-6435` to the host's 127.0.0.1, and the instances
reach that through the host: `host.lima.internal` from a guest,
`host.docker.internal` from a container in one. `ports.nix` holds both that
window and the API one, for the script, the lima configs and the guest image.
No agent workload runs in the cache VM, and a pull-through mirror refuses
pushes, so an agent can read from it but not put an image in it for the
others.

`forge up` runs `forge cache up` first, which checks the three ports answer
and otherwise creates or starts the VM and its mirrors, under a lock in
`~/.local/state/forge/cache.lock` because pi-broker starts several `up`s at
once. A sandboxed agent's `up` gets as far as that check, which is enough
once the cache is running, since `--allow-forge` grants loopback egress.
`forge cache nuke` deletes it and everything it cached.

Two pulls go through it:

- **kindest/node**, which each instance's dockerd pulls, not a node's
  containerd. `guest.nix` gives dockerd `registry-mirrors` pointing at the
  docker.io mirror. dockerd applies that to Docker Hub only, and falls back to
  Docker Hub when the mirror does not answer.
- **Everything a cluster pulls**, through a
  `/etc/containerd/certs.d/<registry>/hosts.toml` forge writes into every
  node, on every `forge up`, before ArgoCD is installed. Each names the cache
  as its `[host]` and the registry itself as `server`, so containerd falls
  back to a direct pull when the cache is down.

An instance created before `guest.nix` carried the dockerd mirror reports
drift on `forge up`, and pulls kindest/node directly until
`forge nuke && forge up` rebuilds it. Its nodes' `hosts.toml` point at the
cache either way.

---

## Management Cluster

A single-node Kind cluster (`forge-mgmt`) runs ArgoCD and serves as the
control plane for all workload clusters.

**ArgoCD** is installed via the official `argo-cd` Helm chart at the chart
version pinned in `forge.yaml` (`management.argocd.version`) in the `argocd`
namespace, fetched with `--repo` rather than a `helm repo add`, since the repo
list is one file every instance would share. `forge-small.yaml` pins it too.
`FORGE_ARGOCD_CHART` swaps in a local or OCI chart and drops the pin. The
server runs in insecure mode (HTTP) since TLS termination is not required in a local environment.

**Workload cluster registration** uses the service-account token approach:
an `argocd-manager` service account is created in `kube-system` of each
workload cluster and bound to the built-in `cluster-admin` ClusterRole. The
resulting bearer token and CA certificate are stored as an ArgoCD cluster
secret named `argocd-cluster-<cluster-name>` (label
`argocd.argoproj.io/secret-type: cluster`) in the `argocd` namespace of the
management cluster. `forge up` skips a cluster only when both the secret and
the service account exist, so a workload cluster recreated under a running
management cluster is registered again with a fresh token.

The API server address used in each cluster secret is the internal Docker
network address (`https://<cluster-name>-control-plane:6443`), which is
reachable from the management cluster because all containers share the `forge`
network.

---

## Workload Clusters

Workload clusters (`forge-1`, `forge-2`) are vanilla Kind clusters. Like the
management cluster, each publishes only its API server, on its port in the
window, which is what the exported kubeconfig targets. Each has one
control-plane node and one worker node. They run no ArgoCD, only the
`argocd-manager` account ArgoCD authenticates as; ArgoCD talks to each API
server directly over the Docker network.

Kind sets containerd's `config_path` when it creates a cluster. The
`hosts.toml` files are written into every node once kind returns, and rewritten
on every `forge up`, before ArgoCD is installed.

---

## Networking

All infrastructure runs on a single Docker bridge network named `forge`.
Container DNS resolution means any container can reach any other by name:

- Cluster API servers: `<cluster-name>-control-plane:6443`
- The cache: `host.docker.internal:6420-6422`

There are no Kubernetes `NodePort` or `LoadBalancer` services involved in
cluster-to-cluster communication. ArgoCD accesses workload clusters via the
Docker network directly.

To access ArgoCD locally:

```
kubectl --context kind-forge-mgmt port-forward svc/argocd-server -n argocd 8080:80
```

---

## Lifecycle

| Command            | VM      | Clusters | Network | Cache  |
| ------------------ | ------- | -------- | ------- | ------ |
| `forge init`       | define  | -        | -       | -      |
| `forge up`         | create  | create   | create  | create |
| `forge down`       | -       | delete   | -       | -      |
| `forge nuke`       | delete  | delete   | delete  | -      |
| `forge cache nuke` | -       | -        | -       | delete |
| `forge status`     | -       | -        | -       | -      |
| `forge ls`         | -       | -        | -       | -      |
| `forge resize`     | restart | -        | -       | -      |

`forge init` writes the VM's lima definition and leaves it stopped, which is
all pi's `--allow-forge` checks for, so a session can hold the grant before
the first `forge up`.

`forge up` creates what is declared and missing, starts a stopped VM, and
leaves everything else alone. It does not resize an existing cluster or
upgrade ArgoCD once it is installed; both take `forge down && forge up`.

`forge down` destroys the clusters `forge.yaml` names (and their kubeconfig
contexts) but leaves the VM and the images it pulled. A cluster dropped from
`forge.yaml` survives both `up` and `down`. `down` needs the VM running.

`forge nuke` deletes the VM, which takes the clusters, network and every
image it pulled with it. The cache keeps its own copy. For the unnamed instance it touches
nothing on the host, so the kubeconfig contexts survive pointing at dead
ports; run `forge down` first to drop them. A named instance's
`~/.local/state/forge/<n>` goes with its VM.

`forge nuke --all` runs `nuke` on every named instance, one after another,
and leaves the unnamed one. It refuses while any forge command is running
against one of them; `--force` stops those first, along with the kind, helm
and docker processes under them.

`forge status` is read-only: the VM, whether the cache answers, and each
cluster's context and API port.

`forge ls` is read-only too, and covers every VM on the host at once, the
cache included:
VM state and size, the forge command running against it if any, clusters
running of those declared, the guest's load, memory and disk, and the pi
agent holding it. It reads `~/.lima`, so it works only outside pi's sandbox.
The procedure for an instance that looks broken is the `forge-debug` Claude
skill (`nix/modules/hm_modules/dev/claude-code/skills/forge-debug.md`).

---

## Kubeconfig

Every cluster shares one file, `kubeconfig` in `forge.yaml`, defaulting to
`~/.local/state/forge/kubeconfig.yaml`. Contexts follow the Kind convention:
`kind-forge-mgmt`, `kind-forge-1`, `kind-forge-2`.

```bash
export KUBECONFIG=~/.local/state/forge/kubeconfig.yaml
kubectl --context kind-forge-1 get nodes
```

`kind create cluster` and `kind delete cluster` are both given `--kubeconfig`,
so nothing under `~/.kube` is read or written and `~/.kube/config` is never
created. Two things depend on that. `~/.kube/config` is not forge's file to
create, and `.kube` is one of the `credentialMasks` entries in
`nix/pkgs/pi-wrapper/default.nix`, so anything forge left there would be
unreadable to a sandboxed agent. `wrapper.sh` states the rule this follows:
the paths a container orchestrator writes belong to whoever configures the
tool.

`forge up` also re-exports the context of every cluster that already exists, so
deleting the file loses nothing the next `up` cannot restore.

The default still sits under `$HOME`, which the sandbox denies wholesale. pi's
`--allow-forge` grants that one path, plus the loopback egress its API servers
need. `FORGE_KUBECONFIG` overrides the config for a caller that would rather
place the file itself, but `--allow-forge` grants only the default path.
