package cluster

import (
	"strings"
	"testing"
)

func TestGenerateDnsmasqConfig(t *testing.T) {
	cfg, err := Load(writeConfig(t, validConfig))
	if err != nil {
		t.Fatal(err)
	}
	body, err := GenerateDnsmasqConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	// Management cluster's MetalLB pool is 172.20.200.0/24 → ingress 172.20.200.1
	// Workload forge-1's pool is 172.20.201.0/24 → ingress 172.20.201.1
	for _, want := range []string{
		"no-resolv",
		"domain-needed",
		"address=/forge-mgmt.forge.test/172.20.200.1",
		"address=/forge-1.forge.test/172.20.201.1",
		"address=/forge.test/172.20.200.1", // catch-all → management
	} {
		if !strings.Contains(body, want) {
			t.Errorf("dnsmasq.conf missing %q:\n%s", want, body)
		}
	}
}

func TestGenerateDnsmasqConfigSkipsClustersWithoutPool(t *testing.T) {
	cfg, err := Load(writeConfig(t, validConfig))
	if err != nil {
		t.Fatal(err)
	}
	// Clear forge-1's pool; it should drop from the dnsmasq output.
	cfg.Clusters[0].MetalLBPool = ""
	body, err := GenerateDnsmasqConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(body, "forge-1.forge.test") {
		t.Errorf("cluster without pool should not appear:\n%s", body)
	}
	if !strings.Contains(body, "forge-mgmt.forge.test") {
		t.Errorf("management cluster should still appear:\n%s", body)
	}
}
