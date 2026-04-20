package lock

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
)

func TestAcquireRelease(t *testing.T) {
	dir := t.TempDir()
	l, err := Acquire(dir, "spec", "main")
	if err != nil {
		t.Fatal(err)
	}
	if l.WasStale() {
		t.Error("fresh acquire should not be stale")
	}
	if _, err := os.Stat(filepath.Join(dir, "spec-main", "lock.json")); err != nil {
		t.Errorf("lock.json missing: %v", err)
	}
	if err := l.Release(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "spec-main")); !os.IsNotExist(err) {
		t.Errorf("lock dir should be gone after Release; err=%v", err)
	}
}

func TestAcquireBlockedByLive(t *testing.T) {
	dir := t.TempDir()
	a, err := Acquire(dir, "spec", "main")
	if err != nil {
		t.Fatal(err)
	}
	defer a.Release()

	_, err = Acquire(dir, "spec", "main")
	if !errors.Is(err, ErrHeld) {
		t.Errorf("expected ErrHeld; got %v", err)
	}
}

func TestAcquireBreaksStale(t *testing.T) {
	dir := t.TempDir()
	lockDir := filepath.Join(dir, "spec-main")
	if err := os.MkdirAll(lockDir, 0o755); err != nil {
		t.Fatal(err)
	}

	deadPID := findDeadPID(t)

	meta := Meta{PID: deadPID, Phase: "spec", ID: "main"}
	b, _ := json.Marshal(meta)
	if err := os.WriteFile(filepath.Join(lockDir, "lock.json"), b, 0o644); err != nil {
		t.Fatal(err)
	}

	l, err := Acquire(dir, "spec", "main")
	if err != nil {
		t.Fatalf("expected stale-break to succeed; got %v", err)
	}
	if !l.WasStale() {
		t.Error("WasStale should be true after breaking dead-PID lock")
	}
	_ = l.Release()
}

// findDeadPID spawns a sleep, kills it, and returns its (now defunct) PID.
// The PID is guaranteed not to be reused by the OS for the duration of the
// test, since we leave the zombie around in our process table.
func findDeadPID(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("sleep", "0.001")
	if err := cmd.Start(); err != nil {
		t.Fatalf("spawn sleep: %v", err)
	}
	pid := cmd.Process.Pid
	if err := cmd.Wait(); err != nil {
		// sleep can't fail meaningfully here; ignore Wait errors.
		_ = err
	}
	// Confirm it really is dead by sending signal 0.
	if err := syscall.Kill(pid, 0); err == nil {
		t.Fatalf("PID %d is still alive after Wait", pid)
	}
	return pid
}

func TestAcquireBreaksMissingLockJSON(t *testing.T) {
	dir := t.TempDir()
	lockDir := filepath.Join(dir, "spec-main")
	if err := os.MkdirAll(lockDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// No lock.json — partial-acquire crash. Should be considered stale.
	l, err := Acquire(dir, "spec", "main")
	if err != nil {
		t.Fatalf("expected stale-break; got %v", err)
	}
	if !l.WasStale() {
		t.Error("WasStale should be true when lock dir lacks lock.json")
	}
	_ = l.Release()
}

func TestInspectReturnsLiveMeta(t *testing.T) {
	dir := t.TempDir()
	l, err := Acquire(dir, "task", "T01")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Release()

	m, alive, err := Inspect(dir, "task", "T01")
	if err != nil {
		t.Fatal(err)
	}
	if m == nil {
		t.Fatal("Inspect: meta is nil")
	}
	if !alive {
		t.Error("Inspect: should be alive (current PID holds it)")
	}
	if m.PID != os.Getpid() {
		t.Errorf("PID: got %d want %d", m.PID, os.Getpid())
	}
}

func TestAllListsLocks(t *testing.T) {
	dir := t.TempDir()
	a, _ := Acquire(dir, "task", "T01")
	defer a.Release()
	b, _ := Acquire(dir, "verify", "T02")
	defer b.Release()

	results, err := All(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 2 {
		t.Errorf("All: got %d locks want 2", len(results))
	}
	for _, r := range results {
		if !r.Alive {
			t.Errorf("%s: should be alive", r.Name)
		}
	}
}
