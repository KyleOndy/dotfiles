package cluster

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestValidateDAGAcceptsValidGraph(t *testing.T) {
	nodes := []Step{
		{ID: "a"},
		{ID: "b", Deps: []string{"a"}},
		{ID: "c", Deps: []string{"a", "b"}},
	}
	if err := ValidateDAG(nodes); err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestValidateDAGDetectsDuplicateIDs(t *testing.T) {
	nodes := []Step{{ID: "a"}, {ID: "a"}}
	if err := ValidateDAG(nodes); err == nil || !strings.Contains(err.Error(), "duplicate") {
		t.Errorf("want duplicate error, got %v", err)
	}
}

func TestValidateDAGDetectsMissingDep(t *testing.T) {
	nodes := []Step{{ID: "a", Deps: []string{"b"}}}
	if err := ValidateDAG(nodes); err == nil || !strings.Contains(err.Error(), "missing") {
		t.Errorf("want missing-dep error, got %v", err)
	}
}

func TestValidateDAGDetectsCycle(t *testing.T) {
	nodes := []Step{
		{ID: "a", Deps: []string{"b"}},
		{ID: "b", Deps: []string{"a"}},
	}
	if err := ValidateDAG(nodes); err == nil || !strings.Contains(err.Error(), "cycle") {
		t.Errorf("want cycle error, got %v", err)
	}
}

func TestExecuteDAGRunsInOrder(t *testing.T) {
	var order []string
	var mu atomic.Int32 // serialize appends
	track := func(id string) func(context.Context) error {
		return func(context.Context) error {
			// Atomic-ish serial append; we just care each node runs exactly once.
			mu.Add(1)
			order = append(order, id)
			return nil
		}
	}
	nodes := []Step{
		{ID: "a", Fn: track("a")},
		{ID: "b", Deps: []string{"a"}, Fn: track("b")},
		{ID: "c", Deps: []string{"b"}, Fn: track("c")},
	}
	results, err := ExecuteDAG(context.Background(), nodes)
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 3 {
		t.Fatalf("want 3 results, got %d", len(results))
	}
	for _, r := range results {
		if r.Err != nil || r.Skipped {
			t.Errorf("%s did not succeed: %+v", r.ID, r)
		}
	}
	// Linear chain: order must be a→b→c.
	if strings.Join(order, ",") != "a,b,c" {
		t.Errorf("order = %v, want a,b,c", order)
	}
}

func TestExecuteDAGRunsIndependentNodesInParallel(t *testing.T) {
	// Three independent nodes each sleeping 100ms. Serial would take 300ms;
	// parallel should be ~100ms. Use 250ms as a generous upper bound.
	slow := func(context.Context) error { time.Sleep(100 * time.Millisecond); return nil }
	nodes := []Step{
		{ID: "a", Fn: slow},
		{ID: "b", Fn: slow},
		{ID: "c", Fn: slow},
	}
	start := time.Now()
	if _, err := ExecuteDAG(context.Background(), nodes); err != nil {
		t.Fatal(err)
	}
	elapsed := time.Since(start)
	if elapsed > 250*time.Millisecond {
		t.Errorf("wall time %v too long — nodes probably ran serially", elapsed)
	}
}

func TestExecuteDAGSkipsDependentsOfFailed(t *testing.T) {
	fail := errors.New("boom")
	nodes := []Step{
		{ID: "root", Fn: func(context.Context) error { return fail }},
		{ID: "child", Deps: []string{"root"}, Fn: func(context.Context) error {
			t.Error("child should not have run")
			return nil
		}},
		{ID: "grandchild", Deps: []string{"child"}, Fn: func(context.Context) error {
			t.Error("grandchild should not have run")
			return nil
		}},
	}
	results, err := ExecuteDAG(context.Background(), nodes)
	if err == nil {
		t.Fatal("expected summary error, got nil")
	}
	resByID := map[string]StepResult{}
	for _, r := range results {
		resByID[r.ID] = r
	}
	if resByID["root"].Err == nil {
		t.Error("root should record its error")
	}
	if !resByID["child"].Skipped {
		t.Error("child should be skipped")
	}
	if !resByID["grandchild"].Skipped {
		t.Error("grandchild should be skipped")
	}
}

func TestBuildUpPlanShape(t *testing.T) {
	cfg, err := Load(writeConfig(t, validConfig))
	if err != nil {
		t.Fatal(err)
	}
	nodes := BuildUpPlan(nil, cfg)
	if err := ValidateDAG(nodes); err != nil {
		t.Fatalf("plan fails validation: %v", err)
	}
	// Shape check: 1 network + 1 dns + 2 mirrors + 2 clusters = 6 nodes.
	if len(nodes) != 6 {
		t.Errorf("node count = %d, want 6", len(nodes))
	}
	byID := map[string]Step{}
	for _, n := range nodes {
		byID[n.ID] = n
	}
	if byID["dns"].Deps[0] != "network" {
		t.Errorf("dns should depend on network")
	}
	for _, cn := range []string{"cluster:forge-mgmt", "cluster:forge-1"} {
		c, ok := byID[cn]
		if !ok {
			t.Fatalf("missing %s", cn)
		}
		depSet := map[string]bool{}
		for _, d := range c.Deps {
			depSet[d] = true
		}
		for _, want := range []string{"network", "dns", "mirror:dockerio", "mirror:ecr"} {
			if !depSet[want] {
				t.Errorf("%s missing dep %s; got %v", cn, want, c.Deps)
			}
		}
	}
}
