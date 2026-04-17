package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

type auditRecord struct {
	Ts         string   `json:"ts"`
	Consumer   string   `json:"consumer"`
	Pid        int      `json:"pid"`
	Cmd        []string `json:"cmd"`
	AllowHosts []string `json:"allow_hosts,omitempty"`
	Binds      []string `json:"binds,omitempty"`
	ExitCode   int      `json:"exit_code"`
	DurationMs int64    `json:"duration_ms"`
	BytesUp    int64    `json:"bytes_up,omitempty"`
	BytesDown  int64    `json:"bytes_down,omitempty"`

	start time.Time
}

func newAuditRecord(cfg *config) *auditRecord {
	r := &auditRecord{
		Consumer:   cfg.consumer,
		Pid:        os.Getpid(),
		Cmd:        cfg.cmd,
		AllowHosts: cfg.allowList,
		start:      time.Now(),
	}
	for _, b := range cfg.binds {
		mode := "rw"
		if b.ro {
			mode = "ro"
		}
		r.Binds = append(r.Binds, b.src+":"+mode)
	}
	return r
}

func (r *auditRecord) finish() {
	r.Ts = time.Now().UTC().Format(time.RFC3339Nano)
	r.DurationMs = time.Since(r.start).Milliseconds()
}

// emitAudit writes a single JSON line to stderr tagged with SYSLOG_IDENTIFIER
// so promtail can filter it from journald when agent-sandbox runs as a
// systemd unit. When run interactively the line appears on stderr.
func emitAudit(r *auditRecord) {
	b, err := json.Marshal(r)
	if err != nil {
		fmt.Fprintf(os.Stderr, "agent-sandbox: audit: %v\n", err)
		return
	}
	fmt.Fprintf(os.Stderr, "[agent-sandbox] %s\n", b)
}
