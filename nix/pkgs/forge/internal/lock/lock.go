// Package lock provides per-phase mutex semantics via mkdir.
//
// Directory creation is atomic on every supported filesystem (APFS, ext4,
// NFS) — that's the actual locking primitive. The lock.json inside the
// directory is just metadata for inspection by other processes (e.g.
// `forge flux show`).
package lock

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

// Meta is what gets persisted as lock.json inside the lock dir.
type Meta struct {
	PID               int       `json:"pid"`
	StartedAt         time.Time `json:"started_at"`
	WasStaleAtAcquire bool      `json:"was_stale_at_acquire"`
	Phase             string    `json:"phase"`
	ID                string    `json:"id"`
}

// Lock is a held per-phase mutex. Caller must Release().
type Lock struct {
	dir  string
	meta Meta

	once   sync.Once
	stopCh chan struct{}
}

// Acquire takes the lock for (phase, id) under locksDir. Returns ErrHeld
// when a live process holds it; stale locks (PID dead) are broken
// automatically and the new lock notes was_stale_at_acquire.
func Acquire(locksDir, phase, id string) (*Lock, error) {
	dir := filepath.Join(locksDir, phase+"-"+id)
	if err := os.MkdirAll(locksDir, 0o755); err != nil {
		return nil, fmt.Errorf("mkdir %s: %w", locksDir, err)
	}
	wasStale := false

	if err := os.Mkdir(dir, 0o755); err != nil {
		if !errors.Is(err, os.ErrExist) {
			return nil, fmt.Errorf("mkdir lock: %w", err)
		}
		// Already exists — examine.
		stale, holderPID, herr := examine(dir)
		if herr != nil {
			return nil, herr
		}
		if !stale {
			return nil, fmt.Errorf("%w: held by PID %d at %s", ErrHeld, holderPID, dir)
		}
		// Break the stale lock.
		if err := os.RemoveAll(dir); err != nil {
			return nil, fmt.Errorf("remove stale lock: %w", err)
		}
		if err := os.Mkdir(dir, 0o755); err != nil {
			return nil, fmt.Errorf("recreate lock dir: %w", err)
		}
		wasStale = true
	}

	l := &Lock{
		dir:    dir,
		stopCh: make(chan struct{}),
		meta: Meta{
			PID:               os.Getpid(),
			StartedAt:         time.Now().UTC(),
			WasStaleAtAcquire: wasStale,
			Phase:             phase,
			ID:                id,
		},
	}
	if err := l.writeMeta(); err != nil {
		os.RemoveAll(dir)
		return nil, err
	}
	l.installSignals()
	return l, nil
}

// ErrHeld means a live process owns the lock.
var ErrHeld = errors.New("lock held")

// Release removes the lock dir. Safe to call multiple times.
func (l *Lock) Release() error {
	var err error
	l.once.Do(func() {
		close(l.stopCh)
		err = os.RemoveAll(l.dir)
	})
	return err
}

// WasStale reports whether this acquire broke a stale prior lock.
func (l *Lock) WasStale() bool { return l.meta.WasStaleAtAcquire }

// Meta returns a copy of the persisted metadata.
func (l *Lock) Meta() Meta { return l.meta }

func (l *Lock) writeMeta() error {
	b, err := json.MarshalIndent(l.meta, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(l.dir, "lock.json"), b, 0o644)
}

// examine returns (stale, holderPID, err) for a lock dir that exists.
// stale=true means the recorded PID is no longer alive and the lock can
// be broken; holderPID is the recorded PID for diagnostics.
func examine(dir string) (bool, int, error) {
	b, err := os.ReadFile(filepath.Join(dir, "lock.json"))
	if err != nil {
		// Lock dir exists but has no lock.json — treat as stale (a partial
		// acquire from a crash).
		return true, 0, nil
	}
	var m Meta
	if err := json.Unmarshal(b, &m); err != nil {
		// Corrupt lock.json: treat as stale.
		return true, 0, nil
	}
	if m.PID == 0 {
		return true, 0, nil
	}
	alive, err := isAlive(m.PID)
	if err != nil {
		return false, m.PID, fmt.Errorf("liveness check: %w", err)
	}
	return !alive, m.PID, nil
}

// isAlive returns true if the PID corresponds to a process that exists.
// Uses kill(pid, 0): no signal sent, only the existence check matters.
func isAlive(pid int) (bool, error) {
	if pid <= 0 {
		return false, nil
	}
	err := syscall.Kill(pid, 0)
	if err == nil {
		return true, nil
	}
	if errors.Is(err, syscall.ESRCH) {
		return false, nil
	}
	if errors.Is(err, syscall.EPERM) {
		// EPERM means the process exists but we lack permission to signal.
		// For our purposes, "exists" = alive.
		return true, nil
	}
	return false, err
}

func (l *Lock) installSignals() {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		select {
		case <-sigCh:
			_ = l.Release()
		case <-l.stopCh:
		}
		signal.Stop(sigCh)
	}()
}

// Inspect returns the metadata for an existing lock dir without acquiring.
// Used by `forge flux show` to report holders.
func Inspect(locksDir, phase, id string) (*Meta, bool, error) {
	dir := filepath.Join(locksDir, phase+"-"+id)
	b, err := os.ReadFile(filepath.Join(dir, "lock.json"))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, false, nil
		}
		return nil, false, err
	}
	var m Meta
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, false, err
	}
	alive, err := isAlive(m.PID)
	if err != nil {
		return &m, false, err
	}
	return &m, alive, nil
}

// All returns metadata for every lock in locksDir along with liveness.
func All(locksDir string) ([]InspectResult, error) {
	entries, err := os.ReadDir(locksDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var out []InspectResult
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		path := filepath.Join(locksDir, e.Name())
		b, err := os.ReadFile(filepath.Join(path, "lock.json"))
		if err != nil {
			out = append(out, InspectResult{Name: e.Name(), Alive: false})
			continue
		}
		var m Meta
		if err := json.Unmarshal(b, &m); err == nil {
			alive, _ := isAlive(m.PID)
			out = append(out, InspectResult{Name: e.Name(), Meta: m, Alive: alive})
		}
	}
	return out, nil
}

// InspectResult bundles per-lock state for read-only callers.
type InspectResult struct {
	Name  string
	Meta  Meta
	Alive bool
}
