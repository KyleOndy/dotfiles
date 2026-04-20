package cluster

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const validConfig = `
apiVersion: forge.dev/v1
network:
  name: forge
  subnet: "172.20.0.0/16"
dns:
  ip: "172.20.0.2"
metallb:
  version: "0.15.3"
mirrors:
  - name: dockerio
    upstream: https://registry-1.docker.io
    registry: docker.io
    host_port: 5100
  - name: ecr
    upstream: https://381491890578.dkr.ecr.us-east-1.amazonaws.com
    registry: 381491890578.dkr.ecr.us-east-1.amazonaws.com
    host_port: 5103
management:
  name: forge-mgmt
  nodes:
    - role: control-plane
  metallb_pool: "172.20.200.0/24"
  components:
    - ingress-nginx
kubeconfig_dir: ~/.kube/configs
clusters:
  - name: forge-1
    nodes:
      - role: control-plane
      - role: worker
    metallb_pool: "172.20.201.0/24"
    components:
      - ingress-nginx
`

func writeConfig(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "forge.yaml")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadValid(t *testing.T) {
	p := writeConfig(t, validConfig)
	c, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.Network.Name != "forge" {
		t.Errorf("Network.Name = %q, want %q", c.Network.Name, "forge")
	}
	if len(c.Mirrors) != 2 {
		t.Errorf("Mirrors len = %d, want 2", len(c.Mirrors))
	}
	if c.Management.Name != "forge-mgmt" {
		t.Errorf("Management.Name = %q", c.Management.Name)
	}
	if len(c.Clusters) != 1 || c.Clusters[0].Name != "forge-1" {
		t.Errorf("Clusters = %+v", c.Clusters)
	}
	if c.Path != p {
		t.Errorf("Path = %q, want %q", c.Path, p)
	}
}

func TestLoadRejectsOldSchema(t *testing.T) {
	// Old schema: flat `network: forge`, `subnet:` top-level, `metallb.pools`,
	// no apiVersion.
	old := `
network: forge
subnet: "172.20.0.0/16"
dns: {ip: "172.20.0.2"}
metallb:
  version: "0.15.3"
  pools:
    forge-mgmt: "172.20.200.0/24"
mirrors: []
management:
  name: forge-mgmt
  nodes: [{role: control-plane}]
clusters: []
`
	_, err := Load(writeConfig(t, old))
	if err == nil {
		t.Fatal("expected error on old schema, got nil")
	}
	// Should complain about apiVersion OR about unknown pools key.
	msg := err.Error()
	if !strings.Contains(msg, "apiVersion") && !strings.Contains(msg, "pools") && !strings.Contains(msg, "field") {
		t.Errorf("unexpected error message: %v", err)
	}
}

func TestValidate(t *testing.T) {
	cases := []struct {
		name string
		edit func(*Config)
		want string
	}{
		{"wrong apiVersion", func(c *Config) { c.APIVersion = "forge.dev/v2" }, "apiVersion"},
		{"bad subnet", func(c *Config) { c.Network.Subnet = "not-a-cidr" }, "network.subnet"},
		{"bad dns ip", func(c *Config) { c.DNS.IP = "999.999.0.1" }, "dns.ip"},
		{"empty mirror upstream", func(c *Config) { c.Mirrors[0].Upstream = "" }, "upstream"},
		{"bad mirror upstream scheme", func(c *Config) { c.Mirrors[0].Upstream = "registry-1.docker.io" }, "upstream"},
		{"empty mirror registry", func(c *Config) { c.Mirrors[0].Registry = "" }, "registry"},
		{"bad mirror port", func(c *Config) { c.Mirrors[0].HostPort = 0 }, "host_port"},
		{"duplicate mirror port", func(c *Config) { c.Mirrors[1].HostPort = c.Mirrors[0].HostPort }, "already used"},
		{"duplicate mirror name", func(c *Config) { c.Mirrors[1].Name = c.Mirrors[0].Name }, "duplicate name"},
		{"no management name", func(c *Config) { c.Management.Name = "" }, "management.name"},
		{"management no nodes", func(c *Config) { c.Management.Nodes = nil }, "management.nodes"},
		{"management no control-plane", func(c *Config) { c.Management.Nodes = []Node{{Role: "worker"}} }, "control-plane"},
		{"bad node role", func(c *Config) { c.Clusters[0].Nodes[0].Role = "bogus" }, "unknown role"},
		{"bad component", func(c *Config) { c.Clusters[0].Components = []string{"kube-prometheus-stack"} }, "unknown component"},
		{"bad metallb_pool", func(c *Config) { c.Clusters[0].MetalLBPool = "nope" }, "metallb_pool"},
		{"duplicate cluster name", func(c *Config) { c.Clusters = append(c.Clusters, c.Management) }, "duplicate cluster"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p := writeConfig(t, validConfig)
			c, err := Load(p)
			if err != nil {
				t.Fatalf("Load: %v", err)
			}
			tc.edit(c)
			err = c.Validate()
			if err == nil {
				t.Fatalf("Validate: expected error containing %q", tc.want)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("Validate error %q does not contain %q", err.Error(), tc.want)
			}
		})
	}
}

func TestDefaults(t *testing.T) {
	minimal := `
apiVersion: forge.dev/v1
mirrors: []
management:
  name: forge-mgmt
  nodes:
    - role: control-plane
clusters: []
`
	c, err := Load(writeConfig(t, minimal))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.Network.Name != NetworkDefaultName {
		t.Errorf("Network.Name = %q, want default %q", c.Network.Name, NetworkDefaultName)
	}
	if c.Network.Subnet != DefaultNetworkSubnet {
		t.Errorf("Network.Subnet = %q, want default %q", c.Network.Subnet, DefaultNetworkSubnet)
	}
	if c.DNS.IP != DefaultDNSIP {
		t.Errorf("DNS.IP = %q, want default %q", c.DNS.IP, DefaultDNSIP)
	}
	if c.KubeconfigDir != DefaultKubeconfigDir {
		t.Errorf("KubeconfigDir = %q", c.KubeconfigDir)
	}
}

func TestMirrorNames(t *testing.T) {
	m := Mirror{Name: "dockerio"}
	if got, want := m.ContainerName(), "forge-mirror-dockerio"; got != want {
		t.Errorf("ContainerName = %q, want %q", got, want)
	}
	if got, want := m.VolumeName(), "forge-mirror-dockerio-data"; got != want {
		t.Errorf("VolumeName = %q, want %q", got, want)
	}
}

func TestAllClusters(t *testing.T) {
	c, err := Load(writeConfig(t, validConfig))
	if err != nil {
		t.Fatal(err)
	}
	all := c.AllClusters()
	if len(all) != 2 {
		t.Fatalf("AllClusters len = %d, want 2", len(all))
	}
	if !all[0].Management {
		t.Error("first entry should be management")
	}
	if all[1].Management {
		t.Error("second entry should not be management")
	}
}

func TestIngressIP(t *testing.T) {
	cases := []struct {
		pool string
		want string
		err  bool
	}{
		{"172.20.200.0/24", "172.20.200.1", false},
		{"10.0.0.0/8", "10.0.0.1", false},
		{"", "", true},
		{"not-a-cidr", "", true},
	}
	for _, tc := range cases {
		t.Run(tc.pool, func(t *testing.T) {
			cl := Cluster{Name: "x", MetalLBPool: tc.pool}
			got, err := cl.IngressIP()
			if tc.err {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got != tc.want {
				t.Errorf("IngressIP = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestFindMirrorByRegistry(t *testing.T) {
	c, err := Load(writeConfig(t, validConfig))
	if err != nil {
		t.Fatal(err)
	}
	if m := c.FindMirrorByRegistry("docker.io"); m == nil || m.Name != "dockerio" {
		t.Errorf("FindMirrorByRegistry(docker.io) = %+v", m)
	}
	if m := c.FindMirrorByRegistry("nonesuch"); m != nil {
		t.Errorf("FindMirrorByRegistry(nonesuch) = %+v, want nil", m)
	}
}

func TestResolvePathEnv(t *testing.T) {
	p := writeConfig(t, validConfig)
	t.Setenv("FORGE_LAB_CONFIG", p)
	c, err := Load("")
	if err != nil {
		t.Fatal(err)
	}
	if c.Path != p {
		t.Errorf("Path = %q, want %q", c.Path, p)
	}
}

func TestExpandHome(t *testing.T) {
	home, _ := os.UserHomeDir()
	cases := []struct{ in, want string }{
		{"~/foo", filepath.Join(home, "foo")},
		{"/abs/path", "/abs/path"},
		{"relative", "relative"},
		{"", ""},
	}
	for _, tc := range cases {
		if got := expandHome(tc.in); got != tc.want {
			t.Errorf("expandHome(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
