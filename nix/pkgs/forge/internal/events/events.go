// Package events writes JSONL event log files under .forge/events/.
package events

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

// Path returns .forge/events/<ts>-<phase>-<id>.jsonl.
func Path(eventsDir, phase, id string) string {
	ts := time.Now().UTC().Format("2006-01-02T150405")
	return filepath.Join(eventsDir, fmt.Sprintf("%s-%s-%s.jsonl", ts, phase, id))
}

// Open creates the parent dir and opens the event log for write.
// Caller closes the returned file.
func Open(path string) (io.WriteCloser, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	return os.Create(path)
}
