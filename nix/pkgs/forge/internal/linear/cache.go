package linear

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// CacheFile is the on-disk shape of the assigned-to-me ticket cache.
type CacheFile struct {
	FetchedAt time.Time       `json:"fetched_at"`
	Issues    []AssignedIssue `json:"issues"`
}

// CachePath returns the assigned-tickets cache location.
// Respects $XDG_CACHE_HOME; falls back to ~/.cache.
func CachePath() string {
	base := os.Getenv("XDG_CACHE_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return filepath.Join(os.TempDir(), "forge-linear-assigned.json")
		}
		base = filepath.Join(home, ".cache")
	}
	return filepath.Join(base, "forge", "linear-assigned.json")
}

// ReadCache loads the cache file. Returns os.ErrNotExist if it hasn't been
// written yet; the caller typically treats that as "kick off a refresh".
func ReadCache() (CacheFile, error) {
	raw, err := os.ReadFile(CachePath())
	if err != nil {
		return CacheFile{}, err
	}
	var c CacheFile
	if err := json.Unmarshal(raw, &c); err != nil {
		return CacheFile{}, fmt.Errorf("parse cache %s: %w", CachePath(), err)
	}
	return c, nil
}

// WriteCache atomically replaces the cache file. Creates parent dirs as needed.
func WriteCache(c CacheFile) error {
	path := CachePath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("mkdir cache dir: %w", err)
	}
	raw, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal cache: %w", err)
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".linear-assigned.json.*")
	if err != nil {
		return fmt.Errorf("create temp cache: %w", err)
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(raw); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return fmt.Errorf("write temp cache: %w", err)
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("rename cache into place: %w", err)
	}
	return nil
}
