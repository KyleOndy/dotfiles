# forge cluster access

forge's kubeconfig is granted and `KUBECONFIG` points at it, so `kubectl`,
`helm` and friends reach the clusters forge runs, with the rights that
kubeconfig carries: cluster-admin on them. The clusters live inside the
same lima VM as the docker daemon, and that VM is the boundary: a
privileged pod is a root shell in a node container away. The wrapper
refuses the grant unless the VM still mounts no host path, the same check
`--allow-docker` answers.

Loopback egress comes with it, because the kubeconfig's API servers listen
on 127.0.0.1. `~/.kube` stays masked: the grant is forge's clusters, not
every credential you keep there.
