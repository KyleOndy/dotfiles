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
`vm.nix` and built from `guest.nix`. `forge` talks to
`~/.lima/forge/sock/docker.sock` and ignores `DOCKER_HOST`.

A kind node runs systemd, so it needs a privileged container, and a privileged
container is root on whatever the VM can see. That makes the VM the boundary
rather than the daemon, so it mounts no host path and forwards only the API
port window (`6440-6455`, one port per cluster, assigned by position in
`forge.yaml`) plus the docker socket. Everything else is denied, which is why a
cluster's ingress is not reachable from the host.

`forge up` warns when the running instance no longer matches `vm.nix`, which
happens after any change to the guest image or the port window. Rolling it
forward means `forge nuke && forge up`, since a VM cannot be reconfigured
without deleting the clusters inside it.

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
an `argocd-manager` service account with cluster-admin privileges is created in
`kube-system` of each workload cluster. The resulting bearer token and CA
certificate are stored as an ArgoCD cluster secret (label
`argocd.argoproj.io/secret-type: cluster`) in the `argocd` namespace of the
management cluster.

The API server address used in each cluster secret is the internal Docker
network address (`https://<cluster-name>-control-plane:6443`), which is
reachable from the management cluster because all containers share the `forge`
network.

---

## Workload Clusters

Workload clusters (`forge-1`, `forge-2`) are vanilla Kind clusters with no
host port mappings. Each has one control-plane node and one worker node. They
have no knowledge of ArgoCD; ArgoCD pulls credentials from its cluster secrets
and communicates with each cluster's API server directly over the Docker network.

Mirrors are pre-configured on every node at cluster creation time before any
workloads run.

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

| Command      | VM     | Clusters | Mirrors | Volumes | Network |
| ------------ | ------ | -------- | ------- | ------- | ------- |
| `forge up`   | create | create   | create  | create  | create  |
| `forge down` | -      | delete   | -       | -       | -       |
| `forge nuke` | delete | delete   | delete  | delete  | delete  |

`forge up` is fully idempotent: re-running it converges to the desired state
without recreating resources that already exist.

`forge down` destroys all clusters (and removes their kubeconfigs) but leaves
mirrors and their cache volumes intact, allowing subsequent `forge up` runs to
benefit from cached layers.

`forge nuke` deletes the VM, which takes the clusters, mirrors, volumes,
network and every pulled image with it.

---

## Kubeconfig

Each cluster's kubeconfig is exported to `~/.kube/configs/<cluster-name>.yaml`
at creation time. Contexts follow the Kind convention: `kind-<cluster-name>`.

Example contexts:

- `kind-forge-mgmt`
- `kind-forge-1`
- `kind-forge-2`
