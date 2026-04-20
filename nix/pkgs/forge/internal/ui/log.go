package ui

import (
	"fmt"
	"os"
	"time"
)

// Logger writes timestamped, color-tagged log lines to stderr.
// Format: [ISO8601] [LEVEL] message
type Logger struct{}

func L() *Logger { return &Logger{} }

func (Logger) Info(format string, args ...any)  { write("INFO ", "green", format, args...) }
func (Logger) Warn(format string, args ...any)  { write("WARN ", "yellow", format, args...) }
func (Logger) Error(format string, args ...any) { write("ERROR", "red", format, args...) }

// Debug writes only when DEBUG env var is set (any non-empty value).
func (Logger) Debug(format string, args ...any) {
	if os.Getenv("DEBUG") == "" {
		return
	}
	write("DEBUG", "blue", format, args...)
}

func write(level, color, format string, args ...any) {
	ts := time.Now().Format(time.RFC3339)
	msg := fmt.Sprintf(format, args...)
	fmt.Fprintf(os.Stderr, "[%s] %s[%s]%s %s\n", ts, Color(color), level, Color("reset"), msg)
}
