// Package cluster holds the forge lab Kind multi-cluster dev environment:
// config parsing, Docker network, pull-through registry mirrors, Kind cluster
// lifecycle, MetalLB, DNS, and component deployment.
//
// This file defines the on-disk schema (forge.yaml v1), its loader, and a
// handful of derived helpers used by the rest of the package.
package cluster

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// APIVersionV1 is the current schema version. Non-matching configs are
// rejected so we can introduce breaking changes later with a clean upgrade
// path.
const APIVersionV1 = "forge.dev/v1"

// Resource name constants, applied when building container / volume / network
// names so that discovery can find forge-owned resources by prefix.
const (
	NetworkDefaultName    = "forge"
	ClusterPrefix         = "forge-"
	MirrorContainerPrefix = "forge-mirror-"
	DNSContainerName      = "forge-dns"
	DNSImageName          = "forge-dns:latest"
	DefaultKubeconfigDir  = "~/.kube/configs"
	DefaultNetworkSubnet  = "172.20.0.0/16"
	DefaultDNSIP          = "172.20.0.2"
	NodeRoleControlPlane  = "control-plane"
	NodeRoleWorker        = "worker"
	ComponentIngressNginx = "ingress-nginx"
)

// AllowedComponents is the set of component names accepted in v1. Anything
// else in a cluster's `components:` list is rejected at validation time.
var AllowedComponents = map[string]struct{}{
	ComponentIngressNginx: {},
}

// AllowedNodeRoles is the set of roles accepted in a cluster's `nodes:` list.
var AllowedNodeRoles = map[string]struct{}{
	NodeRoleControlPlane: {},
	NodeRoleWorker:       {},
}

// Config is the parsed forge.yaml. Field names mirror the YAML keys.
type Config struct {
	APIVersion    string    `yaml:"apiVersion"`
	Network       Network   `yaml:"network"`
	DNS           DNS       `yaml:"dns"`
	MetalLB       MetalLB   `yaml:"metallb"`
	Mirrors       []Mirror  `yaml:"mirrors"`
	Management    Cluster   `yaml:"management"`
	KubeconfigDir string    `yaml:"kubeconfig_dir"`
	Clusters      []Cluster `yaml:"clusters"`

	// Path is the resolved filesystem path the config was loaded from. Not
	// serialized — set by Load.
	Path string `yaml:"-"`
}

// Network describes the shared Docker bridge network that backs every forge
// cluster and mirror container.
type Network struct {
	Name   string `yaml:"name"`
	Subnet string `yaml:"subnet"`
}

// DNS carries the static address assigned to the forge-dns container.
type DNS struct {
	IP string `yaml:"ip"`
}

// MetalLB pins the load-balancer version. Per-cluster pool CIDRs live on the
// individual Cluster records to avoid the silent-name-match coupling the old
// schema had.
type MetalLB struct {
	Version string `yaml:"version"`
}

// Mirror configures one pull-through registry cache. Both Upstream and
// Registry are required: Upstream is the HTTPS endpoint the mirror proxies
// to, Registry is the DNS name as it appears in image references (which can
// differ from the Upstream hostname — e.g. docker.io vs registry-1.docker.io).
type Mirror struct {
	Name     string `yaml:"name"`
	Upstream string `yaml:"upstream"`
	Registry string `yaml:"registry"`
	HostPort int    `yaml:"host_port"`
}

// Cluster is either a management or workload cluster. The distinction is made
// by top-level key in forge.yaml (`management:` vs. an entry in `clusters:`),
// not a field on Cluster itself.
type Cluster struct {
	Name        string   `yaml:"name"`
	Nodes       []Node   `yaml:"nodes"`
	MetalLBPool string   `yaml:"metallb_pool"`
	Components  []string `yaml:"components"`
}

// Node is one Kind node in a cluster.
type Node struct {
	Role string `yaml:"role"`
}

// ClusterRef pairs a Cluster with its role flag. AllClusters returns these so
// callers that iterate can treat management and workload uniformly while
// still knowing which is which.
type ClusterRef struct {
	Cluster
	Management bool
}

// Load reads and validates forge.yaml. Path resolution: explicit path first,
// then $FORGE_LAB_CONFIG, then ./forge.yaml.
func Load(explicit string) (*Config, error) {
	path, err := resolvePath(explicit)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	var c Config
	dec := yaml.NewDecoder(strings.NewReader(string(data)))
	dec.KnownFields(true) // reject unknown keys — catches typos early
	if err := dec.Decode(&c); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	c.Path = path
	c.applyDefaults()
	if err := c.Validate(); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &c, nil
}

// resolvePath picks the forge.yaml path per the documented precedence.
func resolvePath(explicit string) (string, error) {
	if explicit != "" {
		return expandHome(explicit), nil
	}
	if env := os.Getenv("FORGE_LAB_CONFIG"); env != "" {
		return expandHome(env), nil
	}
	return "forge.yaml", nil
}

// applyDefaults fills in optional fields with the documented fallback values.
// Called after YAML decode but before Validate so required-field checks see a
// fully-populated config.
func (c *Config) applyDefaults() {
	if c.Network.Name == "" {
		c.Network.Name = NetworkDefaultName
	}
	if c.Network.Subnet == "" {
		c.Network.Subnet = DefaultNetworkSubnet
	}
	if c.DNS.IP == "" {
		c.DNS.IP = DefaultDNSIP
	}
	if c.KubeconfigDir == "" {
		c.KubeconfigDir = DefaultKubeconfigDir
	}
}

// Validate returns a joined error describing every problem it finds so that
// users see the full list in one pass instead of fixing issues one at a time.
func (c *Config) Validate() error {
	var errs []error

	if c.APIVersion != APIVersionV1 {
		errs = append(errs, fmt.Errorf("apiVersion: want %q, got %q", APIVersionV1, c.APIVersion))
	}

	if _, _, err := net.ParseCIDR(c.Network.Subnet); err != nil {
		errs = append(errs, fmt.Errorf("network.subnet: %w", err))
	}
	if c.Network.Name == "" {
		errs = append(errs, errors.New("network.name: required"))
	}
	if ip := net.ParseIP(c.DNS.IP); ip == nil {
		errs = append(errs, fmt.Errorf("dns.ip: not a valid IP: %q", c.DNS.IP))
	}

	names := map[string]int{}
	hostPorts := map[int]string{}
	for i, m := range c.Mirrors {
		prefix := fmt.Sprintf("mirrors[%d]", i)
		if m.Name == "" {
			errs = append(errs, fmt.Errorf("%s.name: required", prefix))
		}
		names[m.Name]++
		if m.Upstream == "" {
			errs = append(errs, fmt.Errorf("%s.upstream: required", prefix))
		} else if u, err := url.Parse(m.Upstream); err != nil || u.Scheme == "" || u.Host == "" {
			errs = append(errs, fmt.Errorf("%s.upstream: must be an absolute URL with scheme and host", prefix))
		}
		if m.Registry == "" {
			errs = append(errs, fmt.Errorf("%s.registry: required", prefix))
		}
		if m.HostPort <= 0 || m.HostPort > 65535 {
			errs = append(errs, fmt.Errorf("%s.host_port: must be 1..65535", prefix))
		}
		if prev, ok := hostPorts[m.HostPort]; ok && m.HostPort > 0 {
			errs = append(errs, fmt.Errorf("%s.host_port: %d already used by mirror %q", prefix, m.HostPort, prev))
		}
		hostPorts[m.HostPort] = m.Name
	}
	for name, n := range names {
		if n > 1 {
			errs = append(errs, fmt.Errorf("mirrors: duplicate name %q", name))
		}
	}

	errs = append(errs, validateCluster("management", c.Management)...)
	clusterNames := map[string]bool{c.Management.Name: true}
	for i, cl := range c.Clusters {
		prefix := fmt.Sprintf("clusters[%d]", i)
		errs = append(errs, validateCluster(prefix, cl)...)
		if clusterNames[cl.Name] {
			errs = append(errs, fmt.Errorf("%s.name: duplicate cluster name %q", prefix, cl.Name))
		}
		clusterNames[cl.Name] = true
	}

	return errors.Join(errs...)
}

// validateCluster returns errors for one Cluster record.
func validateCluster(prefix string, c Cluster) []error {
	var errs []error
	if c.Name == "" {
		errs = append(errs, fmt.Errorf("%s.name: required", prefix))
	}
	if len(c.Nodes) == 0 {
		errs = append(errs, fmt.Errorf("%s.nodes: at least one node required", prefix))
	}
	cpCount := 0
	for i, n := range c.Nodes {
		if _, ok := AllowedNodeRoles[n.Role]; !ok {
			errs = append(errs, fmt.Errorf("%s.nodes[%d].role: unknown role %q (want one of %s)", prefix, i, n.Role, strings.Join(sortedKeys(AllowedNodeRoles), ", ")))
		}
		if n.Role == NodeRoleControlPlane {
			cpCount++
		}
	}
	if cpCount == 0 && len(c.Nodes) > 0 {
		errs = append(errs, fmt.Errorf("%s.nodes: no control-plane role found", prefix))
	}
	if c.MetalLBPool != "" {
		if _, _, err := net.ParseCIDR(c.MetalLBPool); err != nil {
			errs = append(errs, fmt.Errorf("%s.metallb_pool: %w", prefix, err))
		}
	}
	for i, comp := range c.Components {
		if _, ok := AllowedComponents[comp]; !ok {
			errs = append(errs, fmt.Errorf("%s.components[%d]: unknown component %q (want one of %s)", prefix, i, comp, strings.Join(sortedKeys(AllowedComponents), ", ")))
		}
	}
	return errs
}

// ContainerName returns the Docker container name that backs this mirror.
func (m Mirror) ContainerName() string {
	return MirrorContainerPrefix + m.Name
}

// VolumeName returns the Docker volume name that persists this mirror's cache
// across `lab down`/`lab up` cycles.
func (m Mirror) VolumeName() string {
	return MirrorContainerPrefix + m.Name + "-data"
}

// AllClusters returns management + workload clusters in a single slice with
// the Management flag set so callers can tell them apart without branching on
// a separate code path.
func (c *Config) AllClusters() []ClusterRef {
	out := make([]ClusterRef, 0, 1+len(c.Clusters))
	out = append(out, ClusterRef{Cluster: c.Management, Management: true})
	for _, cl := range c.Clusters {
		out = append(out, ClusterRef{Cluster: cl})
	}
	return out
}

// FindMirrorByRegistry returns the mirror whose Registry matches the given
// image-ref registry string, or nil.
func (c *Config) FindMirrorByRegistry(registry string) *Mirror {
	for i := range c.Mirrors {
		if c.Mirrors[i].Registry == registry {
			return &c.Mirrors[i]
		}
	}
	return nil
}

// ExpandedKubeconfigDir returns KubeconfigDir with ~ expanded to $HOME.
func (c *Config) ExpandedKubeconfigDir() string {
	return expandHome(c.KubeconfigDir)
}

// IngressIP returns the first host address of the cluster's MetalLB pool —
// i.e. the IP an ingress-nginx LoadBalancer Service will land on. Returns an
// error when MetalLBPool is empty or unparseable.
//
// Example: "172.20.200.0/24" -> "172.20.200.1"
func (c Cluster) IngressIP() (string, error) {
	if c.MetalLBPool == "" {
		return "", fmt.Errorf("cluster %q has no metallb_pool", c.Name)
	}
	ip, _, err := net.ParseCIDR(c.MetalLBPool)
	if err != nil {
		return "", fmt.Errorf("cluster %q: %w", c.Name, err)
	}
	ip4 := ip.To4()
	if ip4 == nil {
		return "", fmt.Errorf("cluster %q: only IPv4 pools supported", c.Name)
	}
	ip4[3]++
	return ip4.String(), nil
}

// KindClusterName returns the Docker-facing name of a cluster as Kind creates
// it. Kind prefixes cluster names with the role when assigning container
// names; we name ours with the forge- prefix already baked in, so the Kind
// container is simply "<Name>-control-plane" / "<Name>-worker".
func (c Cluster) KindClusterName() string {
	return c.Name
}

// expandHome does cheap ~-to-$HOME substitution. yaml values are usually
// short, so we don't pull in a package for this.
func expandHome(p string) string {
	if p == "" || !strings.HasPrefix(p, "~") {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return p
	}
	rest := strings.TrimPrefix(p, "~")
	return filepath.Join(home, rest)
}

// sortedKeys returns the keys of m in sorted order. Used only for
// deterministic error messages.
func sortedKeys(m map[string]struct{}) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	// cheap sort without pulling in sort package — the sets are tiny
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j-1] > out[j]; j-- {
			out[j-1], out[j] = out[j], out[j-1]
		}
	}
	return out
}
