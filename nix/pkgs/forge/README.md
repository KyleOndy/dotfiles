# Forge

Packaged as `pkgs.forge`; config is read from `$XDG_CONFIG_HOME/forge/forge.yaml`,
which work-mac populates from `forge.yaml` beside this README. `FORGE_CONFIG`
overrides the path.

## Purpose

Forge provisions and manages a local multi-cluster Kubernetes environment for
testing ArgoCD-based GitOps workflows. It handles **layer 1** infrastructure:
Docker networking, pull-through registry mirrors, Kind clusters, ArgoCD
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
        ├── forge-mirror-dockerio   (registry:2 → registry-1.docker.io)
        ├── forge-mirror-ghcrio     (registry:2 → ghcr.io)
        ├── forge-mirror-quayio     (registry:2 → quay.io)
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
(`~/.lima/forge/lima.yaml`) differs from what `vm.nix` builds. Any edit to
`vm.nix` or `guest.nix` does that, and so does a hand edit of the instance.
Rolling it forward means `forge nuke && forge up`, since a VM cannot be
reconfigured without deleting the clusters inside it.

The flake check `forge-vm` (`nix/checks/forge-vm.nix`) holds that boundary: no
mounts, a docker socket forward, the API window on both address families, a
deny-all pair at the end of `portForwards`, and a script that creates its VM
from the same config.

---

## Pull-Through Mirrors

Three `registry:2` containers act as caching pull-through proxies:

| Container               | Upstream                       | Fronts      |
| ----------------------- | ------------------------------ | ----------- |
| `forge-mirror-dockerio` | `https://registry-1.docker.io` | `docker.io` |
| `forge-mirror-ghcrio`   | `https://ghcr.io`              | `ghcr.io`   |
| `forge-mirror-quayio`   | `https://quay.io`              | `quay.io`   |

Each mirror stores its cache in a named Docker volume (`forge-mirror-<name>-data`),
which persists across `forge down` cycles. Mirrors are reachable by all cluster
nodes at `http://forge-mirror-<name>:5000`.

### Containerd configuration

Each Kind node is configured to use the mirrors via containerd's
`/etc/containerd/certs.d/<registry>/hosts.toml` mechanism. The `config_path`
directive in the containerd config points to `/etc/containerd/certs.d`, and a
`hosts.toml` is written into the appropriate subdirectory for each registry:

```
/etc/containerd/certs.d/docker.io/hosts.toml
/etc/containerd/certs.d/ghcr.io/hosts.toml
/etc/containerd/certs.d/quay.io/hosts.toml
```

Each `hosts.toml` redirects pulls for that registry to the corresponding mirror
container over plain HTTP on port 5000.

---

## Management Cluster

A single-node Kind cluster (`forge-mgmt`) runs ArgoCD and serves as the
control plane for all workload clusters.

**ArgoCD** is installed via the official `argo/argo-cd` Helm chart at the chart
version pinned in `forge.yaml` (`management.argocd.version`) in the `argocd`
namespace. The server runs in insecure mode (HTTP) since TLS termination is not
required in a local environment.

**Workload cluster registration** uses the service-account token approach:
an `argocd-manager` service account is created in `kube-system` of each
workload cluster and bound to `argocd-manager-role`, a ClusterRole allowing
every verb on every resource. The resulting bearer token and CA certificate are
stored as an ArgoCD cluster secret named `argocd-cluster-<cluster-name>` (label
`argocd.argoproj.io/secret-type: cluster`) in the `argocd` namespace of the
management cluster. `forge up` skips any cluster whose secret already exists,
so a workload cluster recreated under a running management cluster keeps its
old, dead token until the management cluster is recreated too.

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
- Registry mirrors: `forge-mirror-<name>:5000`

There are no Kubernetes `NodePort` or `LoadBalancer` services involved in
cluster-to-cluster communication. ArgoCD accesses workload clusters via the
Docker network directly.

To access ArgoCD locally:

```
kubectl --context kind-forge-mgmt port-forward svc/argocd-server -n argocd 8080:80
```

---

## Lifecycle

| Command        | VM     | Clusters | Mirrors | Volumes | Network |
| -------------- | ------ | -------- | ------- | ------- | ------- |
| `forge up`     | create | create   | create  | create  | create  |
| `forge down`   | -      | delete   | -       | -       | -       |
| `forge nuke`   | delete | delete   | delete  | delete  | delete  |
| `forge status` | -      | -        | -       | -       | -       |

`forge up` creates what is declared and missing, starts a stopped VM or mirror,
and leaves everything else alone. It does not resize an existing cluster,
upgrade ArgoCD once it is installed, or change an existing mirror's upstream.
The first two take `forge down && forge up`, the last `forge nuke`.

`forge down` destroys the clusters `forge.yaml` names (and removes their
kubeconfigs) but leaves mirrors and their cache volumes intact, allowing
subsequent `forge up` runs to benefit from cached layers. A cluster dropped
from `forge.yaml` survives both `up` and `down`. `down` needs the VM running.

`forge nuke` deletes the VM, which takes the clusters, mirrors, volumes,
network and every pulled image with it. It touches nothing on the host, so the
kubeconfigs survive pointing at dead ports; run `forge down` first to drop
them.

`forge status` is read-only: the VM, each mirror's state, and each cluster's
context and API port.

---

## Kubeconfig

Each cluster's kubeconfig is exported to `<kubeconfig_dir>/<cluster-name>.yaml`
at creation time (`~/.kube/configs` as shipped). Kind also merges the context
into `$KUBECONFIG`, or `~/.kube/config` when that is unset, and forge's own
`kubectl` and `helm` calls use that merged copy. Contexts follow the Kind
convention: `kind-<cluster-name>`.

Example contexts:

- `kind-forge-mgmt`
- `kind-forge-1`
- `kind-forge-2`
