package cluster

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

// forgeTestBlockMarker is the substring CoreDNS patching uses to detect an
// already-patched Corefile. Idempotency check happens on substring match;
// reformatting the block would require re-patching, which is acceptable.
const forgeTestBlockMarker = "forge.test:53"

// forgeTestServerBlock renders the CoreDNS server block that forwards
// forge.test queries to the forge-dns container's IP.
func forgeTestServerBlock(dnsIP string) string {
	return fmt.Sprintf(`
forge.test:53 {
    forward . %s
    cache 30
}
`, dnsIP)
}

// PatchCoreDNS adds a `forge.test:53` forward block to one cluster's CoreDNS
// Corefile. Restarts CoreDNS pods after patching so the new block takes
// effect immediately. Idempotent: a Corefile already containing the marker
// is left alone.
func PatchCoreDNS(ctx context.Context, exe Executor, kubeconfigDir, clusterName, dnsIP string) error {
	kubeconfig := filepath.Join(kubeconfigDir, clusterName)
	res, err := exe.Run(ctx, "kubectl", "get", "configmap", "coredns",
		"-n", "kube-system",
		"--kubeconfig", kubeconfig,
		"-o", "jsonpath={.data.Corefile}",
	)
	if err != nil {
		return fmt.Errorf("get CoreDNS configmap on %s: %w\n%s", clusterName, err, res.Stderr)
	}
	corefile := res.Stdout
	if strings.Contains(corefile, forgeTestBlockMarker) {
		ui.L().Info("coredns on %s already has forge.test block, skipping", clusterName)
		return nil
	}
	newCorefile := corefile + forgeTestServerBlock(dnsIP)
	patch, err := json.Marshal(map[string]any{
		"data": map[string]any{
			"Corefile": newCorefile,
		},
	})
	if err != nil {
		return err
	}
	if res, err := exe.Run(ctx, "kubectl", "patch", "configmap", "coredns",
		"-n", "kube-system",
		"--type", "merge",
		"--patch", string(patch),
		"--kubeconfig", kubeconfig,
	); err != nil {
		return fmt.Errorf("patch CoreDNS on %s: %w\n%s", clusterName, err, res.Stderr)
	}
	if res, err := exe.Run(ctx, "kubectl", "rollout", "restart", "deployment/coredns",
		"-n", "kube-system",
		"--kubeconfig", kubeconfig,
	); err != nil {
		return fmt.Errorf("restart CoreDNS on %s: %w\n%s", clusterName, err, res.Stderr)
	}
	ui.L().Info("patched and restarted CoreDNS on %s", clusterName)
	return nil
}
