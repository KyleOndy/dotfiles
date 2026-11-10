# forge, through coordinator agents

Only an agent that `alamode coord --allow-forge` spawns with a `size` holds
a forge instance, and in that agent `FORGE_INSTANCE` is set. Without it,
this session holds no VM, docker socket or kubeconfig, whether it is a plain
session or the coordinator itself: `forge` refuses to run, and neither
/regrant nor a VM the human starts changes that. A coordinator hands cluster
work to an agent spawned with a `size`. To reach a service the human runs on
forge, ask the human for `--listen <port>` on its loopback port.

With `FORGE_INSTANCE` set, the instance is yours alone, and no other agent's
VM is reachable from here. Call `forge_boot` to boot its VM, then run
`forge up`. `FORGE_CONFIG` names the cluster layout the coordinator chose and
is read-only, so do not write a forge config of your own.
`forge down && forge up` rebuilds the clusters; creating or deleting the VM
itself is not possible from inside the sandbox. The coordinator deletes the
VM when it tears you down: nothing kept only inside the VM outlives you, the
branch is what survives.

`DOCKER_HOST` points at the VM's docker socket and `KUBECONFIG` at its
kubeconfig, so `docker`, `kind`, `kubectl` and `helm` reach that VM and its
clusters, with the rights the kubeconfig carries: cluster-admin on them
(contexts `kind-<cluster>`, listed by `kubectl config get-contexts`).
Loopback egress comes with it, because the API servers listen on 127.0.0.1.

The wrapper refuses the grant unless that VM exists, mounts no host path and
denies the port forwards it does not name. That VM is the real boundary:
anything a container can reach, this session can reach through it, and a
privileged pod is a root shell in a node container away. With no host
mounts, $HOME is out of reach, but a privileged container still runs outside
alamode's policy. Build and run what the task needs, not more.

`~/.kube` and `~/.docker` stay masked. `DOCKER_CONFIG` points at a
sandbox-local dir, so stored registry credentials are not available and
private image pulls fail: build the image against `DOCKER_HOST` and
`kind load docker-image` it instead. That is deliberate: the grant buys
forge's clusters, not every credential kept there.
