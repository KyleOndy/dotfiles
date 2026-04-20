package cluster

import (
	"context"
	"fmt"
	"path/filepath"

	"github.com/kyleondy/dotfiles/forge/internal/manifest"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

const metallbNamespace = "metallb-system"

// EnsureMetalLB installs MetalLB and configures its IP pool on one cluster.
// Idempotent across all three steps (apply is server-side, waits are fast
// when already-available).
//
// Steps:
//  1. kubectl apply vendored MetalLB manifest
//  2. kubectl wait for the MetalLB CRDs to be established
//  3. kubectl wait for the controller deployment to be Available
//  4. kubectl apply the per-cluster IPAddressPool + L2Advertisement
func EnsureMetalLB(ctx context.Context, exe Executor, kubeconfigDir string, c Cluster) error {
	if c.MetalLBPool == "" {
		// Clusters without a pool skip MetalLB entirely — LoadBalancer
		// Services won't get IPs, but the cluster still works.
		return nil
	}
	kubeconfig := filepath.Join(kubeconfigDir, c.Name)
	ui.L().Info("installing MetalLB on %s", c.Name)
	if err := kubectlApplyStdin(ctx, string(manifest.MetalLBNativeV0_15_3), kubeconfig); err != nil {
		return fmt.Errorf("apply MetalLB manifest on %s: %w", c.Name, err)
	}
	for _, crd := range []string{"ipaddresspools.metallb.io", "l2advertisements.metallb.io"} {
		if _, err := exe.Run(ctx, "kubectl", "wait",
			"--for=condition=established",
			"crd/"+crd,
			"--timeout=120s",
			"--kubeconfig", kubeconfig,
		); err != nil {
			return fmt.Errorf("wait for CRD %s on %s: %w", crd, c.Name, err)
		}
	}
	if _, err := exe.Run(ctx, "kubectl", "wait",
		"deployment/controller",
		"--for=condition=available",
		"-n", metallbNamespace,
		"--timeout=300s",
		"--kubeconfig", kubeconfig,
	); err != nil {
		return fmt.Errorf("wait for MetalLB controller on %s: %w", c.Name, err)
	}
	pool := renderMetalLBPool(c.MetalLBPool)
	if err := kubectlApplyStdin(ctx, pool, kubeconfig); err != nil {
		return fmt.Errorf("apply MetalLB pool on %s: %w", c.Name, err)
	}
	ui.L().Info("MetalLB ready on %s (pool %s)", c.Name, c.MetalLBPool)
	return nil
}

// renderMetalLBPool returns the IPAddressPool + L2Advertisement YAML for a
// single pool range. Namespace metallb-system must exist already (the
// vendored manifest creates it).
func renderMetalLBPool(poolRange string) string {
	return fmt.Sprintf(`apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: forge-pool
  namespace: %s
spec:
  addresses:
    - %s
  avoidBuggyIPs: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: forge-l2
  namespace: %s
spec:
  ipAddressPools:
    - forge-pool
`, metallbNamespace, poolRange, metallbNamespace)
}

// kubectlApplyStdin pipes the given manifest body into `kubectl apply -f -`
// using the stdinRunner seam so tests can stub it.
func kubectlApplyStdin(ctx context.Context, body, kubeconfig string) error {
	return stdinRunner(ctx, body, "kubectl", "apply", "-f", "-", "--kubeconfig", kubeconfig)
}
