// Package ui owns terminal output: ANSI colors, structured logger, confirm
// prompts. Colors auto-disable when stderr is not a TTY or when NO_COLOR
// is set (https://no-color.org).
package ui

import (
	"os"
	"sync"

	"golang.org/x/term"
)

// Gruvbox 256-color palette.
const (
	red    = "\033[38;5;167m"
	green  = "\033[38;5;142m"
	yellow = "\033[38;5;214m"
	blue   = "\033[38;5;109m"
	bold   = "\033[1m"
	reset  = "\033[0m"
)

var (
	mu       sync.Mutex
	detected bool
	useColor bool
)

// Color returns the ANSI escape for the named color (red/green/yellow/blue/
// bold/reset) or empty string when color output is disabled.
func Color(name string) string {
	if !colorEnabled() {
		return ""
	}
	switch name {
	case "red":
		return red
	case "green":
		return green
	case "yellow":
		return yellow
	case "blue":
		return blue
	case "bold":
		return bold
	case "reset":
		return reset
	}
	return ""
}

func colorEnabled() bool {
	mu.Lock()
	defer mu.Unlock()
	if !detected {
		if os.Getenv("NO_COLOR") != "" {
			useColor = false
		} else {
			useColor = term.IsTerminal(int(os.Stderr.Fd()))
		}
		detected = true
	}
	return useColor
}

// resetForTest clears the cached detection so a test can re-evaluate.
func resetForTest() {
	mu.Lock()
	defer mu.Unlock()
	detected = false
}
