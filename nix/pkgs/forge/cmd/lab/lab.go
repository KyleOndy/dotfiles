// Package lab is the local Kind multi-cluster dev environment subcommand.
//
// `forge lab` manages Kind clusters, a shared Docker bridge network,
// pull-through registry mirrors, MetalLB, DNS, and deployed components —
// the machinery a small team needs to iterate on cluster-targeted code
// locally. Config lives in forge.yaml (see internal/cluster.Config).
package lab

import "github.com/spf13/cobra"

const configFlag = "config"

// New returns the `forge lab` cobra command tree.
func New() *cobra.Command {
	c := &cobra.Command{
		Use:   "lab",
		Short: "Local Kind multi-cluster dev environment",
		Long: `Manage a local multi-cluster Kubernetes dev environment.

Drives Kind clusters, a shared Docker bridge network, pull-through
registry mirrors, MetalLB load-balancer pools, DNS, and deployed
components. Desired state lives in forge.yaml.

Config resolution: --config flag > $FORGE_LAB_CONFIG > ./forge.yaml`,
	}
	c.PersistentFlags().StringP(configFlag, "c", "", "path to forge.yaml")
	c.AddCommand(newStatus())
	c.AddCommand(newUp())
	c.AddCommand(newDown())
	c.AddCommand(newNuke())
	return c
}

// configPath returns the --config flag value from a subcommand's flags.
func configPath(cmd *cobra.Command) string {
	v, _ := cmd.Flags().GetString(configFlag)
	return v
}
