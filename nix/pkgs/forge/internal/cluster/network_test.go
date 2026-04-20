package cluster

import (
	"context"
	"os/exec"
	"testing"
)

func TestEnsureNetworkCreatesWhenAbsent(t *testing.T) {
	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"docker", "network", "inspect", "forge"}, exit: 1},
		{match: []string{"docker", "network", "create", "--driver", "bridge", "--subnet", "172.20.0.0/16", "forge"}, exit: 0},
	}}
	err := EnsureNetwork(context.Background(), f, "forge", "172.20.0.0/16")
	if err != nil {
		t.Fatal(err)
	}
}

func TestEnsureNetworkSkipsWhenPresent(t *testing.T) {
	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"docker", "network", "inspect", "forge"}, exit: 0},
		// No create call should be attempted; fakeExec fails on unexpected calls.
	}}
	if err := EnsureNetwork(context.Background(), f, "forge", ""); err != nil {
		t.Fatal(err)
	}
}

func TestEnsureNetworkWithoutSubnet(t *testing.T) {
	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"docker", "network", "inspect", "forge"}, exit: 1},
		{match: []string{"docker", "network", "create", "--driver", "bridge", "forge"}, exit: 0},
	}}
	if err := EnsureNetwork(context.Background(), f, "forge", ""); err != nil {
		t.Fatal(err)
	}
}

func TestDeleteNetworkSkipsWhenAbsent(t *testing.T) {
	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"docker", "network", "inspect", "forge"}, exit: 1},
	}}
	if err := DeleteNetwork(context.Background(), f, "forge"); err != nil {
		t.Fatal(err)
	}
}

func TestConnectNodeTreatsAlreadyConnectedAsSuccess(t *testing.T) {
	// Docker returns non-zero + "already exists in network" when the node
	// is already attached. That must not be a failure.
	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"docker", "network", "connect", "forge", "forge-1-control-plane"}, errOut: "Error: endpoint already exists in network forge", exit: 1},
	}}
	if err := ConnectNodeToNetwork(context.Background(), f, "forge", "forge-1-control-plane"); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestConnectNodeSurfacesRealErrors(t *testing.T) {
	f := &fakeExec{t: t, calls: []fakeCall{
		{match: []string{"docker", "network", "connect"}, errOut: "some other failure", exit: 1},
	}}
	err := ConnectNodeToNetwork(context.Background(), f, "forge", "n1")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	var ee *exec.ExitError
	_ = ee // silence go vet — actual type-assert optional
}
