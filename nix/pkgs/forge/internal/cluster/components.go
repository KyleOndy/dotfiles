package cluster

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/kyleondy/dotfiles/forge/internal/manifest"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

// ingressNginxNamespace is where the upstream manifest installs the
// controller Deployment + Service.
const ingressNginxNamespace = "ingress-nginx"

// ingressNginxServiceName is the Service that MetalLB assigns an external
// IP to. Annotating it with the cluster's ingress IP pins traffic there.
const ingressNginxServiceName = "ingress-nginx-controller"

// EnsureComponents applies every component listed on a cluster. Depends on
// the cluster being up, connected to the forge network, and with MetalLB
// already installed (for the ingress IP annotation).
func EnsureComponents(ctx context.Context, exe Executor, kubeconfigDir string, c Cluster) error {
	for _, name := range c.Components {
		switch name {
		case ComponentIngressNginx:
			if err := ensureIngressNginx(ctx, exe, kubeconfigDir, c); err != nil {
				return fmt.Errorf("install %s on %s: %w", name, c.Name, err)
			}
		default:
			// Schema validation already rejects unknown components, so this
			// is unreachable. Keep the switch exhaustive-looking for future
			// components anyway.
			return fmt.Errorf("component %q has no installer", name)
		}
	}
	return nil
}

// ensureIngressNginx applies the vendored ingress-nginx manifest, waits for
// the controller to come up, and pins its LoadBalancer IP to the cluster's
// MetalLB pool head address.
func ensureIngressNginx(ctx context.Context, exe Executor, kubeconfigDir string, c Cluster) error {
	kubeconfig := filepath.Join(kubeconfigDir, c.Name)
	ui.L().Info("installing ingress-nginx on %s", c.Name)
	// The upstream manifest doesn't include a Namespace object, so we
	// create one explicitly first. Namespaced resources would otherwise
	// race against their own namespace and fail with "not found".
	if err := ensureNamespace(ctx, exe, kubeconfig, ingressNginxNamespace); err != nil {
		return err
	}
	if err := kubectlApplyStdin(ctx, string(manifest.IngressNginxV4_12_0), kubeconfig); err != nil {
		return fmt.Errorf("apply ingress-nginx manifest: %w", err)
	}
	if res, err := exe.Run(ctx, "kubectl", "wait",
		"deployment/"+ingressNginxServiceName,
		"--for=condition=available",
		"-n", ingressNginxNamespace,
		"--timeout=180s",
		"--kubeconfig", kubeconfig,
	); err != nil {
		return fmt.Errorf("wait for ingress-nginx controller: %w\n%s", err, res.Stderr)
	}
	// Pin the ingress IP via MetalLB's loadBalancerIPs annotation. Only
	// meaningful when the cluster has a MetalLB pool; skip otherwise since
	// the Service won't get an IP anyway.
	if c.MetalLBPool == "" {
		return nil
	}
	ip, err := c.IngressIP()
	if err != nil {
		return err
	}
	if res, err := exe.Run(ctx, "kubectl", "annotate", "service", ingressNginxServiceName,
		"-n", ingressNginxNamespace,
		"--overwrite",
		"metallb.universe.tf/loadBalancerIPs="+ip,
		"--kubeconfig", kubeconfig,
	); err != nil {
		return fmt.Errorf("annotate %s: %w\n%s", ingressNginxServiceName, err, res.Stderr)
	}
	ui.L().Info("ingress-nginx on %s pinned to %s", c.Name, ip)
	return nil
}

// ensureNamespace creates a Kubernetes namespace idempotently: if it
// already exists, that's a success, not an error.
func ensureNamespace(ctx context.Context, exe Executor, kubeconfig, name string) error {
	res, err := exe.Run(ctx, "kubectl", "create", "namespace", name,
		"--kubeconfig", kubeconfig,
	)
	if err == nil {
		return nil
	}
	if strings.Contains(res.Stderr, "AlreadyExists") || strings.Contains(res.Stdout, "AlreadyExists") {
		return nil
	}
	return fmt.Errorf("create namespace %s: %w\n%s", name, err, res.Stderr)
}
