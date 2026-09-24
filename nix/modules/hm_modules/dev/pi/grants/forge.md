# forge access

One forge instance's docker socket and kubeconfig are granted. `DOCKER_HOST`
points at the socket and `KUBECONFIG` at the kubeconfig, so `docker`, `kind`,
`kubectl` and `helm` reach that instance's VM and clusters, with the rights
the kubeconfig carries: cluster-admin on them (contexts `kind-<cluster>`,
listed by `kubectl config get-contexts`). Loopback egress comes with it,
because the API servers listen on 127.0.0.1.

The wrapper refuses the grant unless that VM exists, mounts no host path and
denies the port forwards it does not name. That VM is the real boundary:
anything a container can reach, this session can reach through it, and a
privileged pod is a root shell in a node container away. With no host
mounts, $HOME is out of reach, but a privileged container still runs outside
pi's policy. Build and run what the task needs, not more.

When `FORGE_INSTANCE` is set, the instance is yours alone, and no other
agent's VM is reachable from here. `forge down && forge up` rebuilds its
clusters; creating or deleting the VM itself is not possible from inside the
sandbox. Unset, it is the human's shared instance, and its kubeconfig is
read-only.

`~/.kube` and `~/.docker` stay masked. `DOCKER_CONFIG` points at a
sandbox-local dir, so stored registry credentials are not available and
private image pulls fail. That is deliberate: the grant buys forge's
clusters, not every credential kept there.
