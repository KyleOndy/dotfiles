// Package config resolves runtime configuration from environment variables
// and an optional KEY=value envfile at ~/.config/forge/env.
//
// Process env always wins. The envfile is a convenience for non-secret
// defaults. Complex shell-evaluated secrets (e.g. $(pass show ...)) belong
// in the user's shell init, not the envfile, since forge does not run a
// shell to source it.
package config

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Defaults applied when the env var is unset.
const (
	DefaultAgent     = "pi"
	DefaultModel     = "moonshotai/kimi-k2.5"
	DefaultOpenAITTL = 0
)

// Config holds resolved values for a single forge invocation.
type Config struct {
	Agent             string
	Model             string
	TicketsRoot       string
	AutoApprove       bool
	Quiet             bool
	PermissionMode    string // claude
	AllowedTools      string // space-separated; backend translates
	ExtraDirs         string // colon-separated
	Timeout           time.Duration
	OpenAIBaseURL     string
	OpenAIAPIKey      string
	OpenAITimeout     time.Duration
	LinearAPIKey      string
	ClaudeModel       string
	ClaudeEffort      string
	ClaudeThinkingTok string
	PromptsRoot       string // root of repo-keyed prompt prefix/suffix tree
	Repo              string // override for repo detection; empty → auto from cwd

	// Source tracks where each non-default value came from.
	// Keys: "FORGE_AGENT", "OPENAI_API_KEY", etc. Values: "env" or "envfile".
	Source map[string]string
}

// EnvfilePath returns ~/.config/forge/env (or the path FORGE_ENV_FILE
// points to, for testing).
func EnvfilePath() string {
	if p := os.Getenv("FORGE_ENV_FILE"); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "forge", "env")
}

// Load resolves config. Process env wins; envfile fills in unset vars.
func Load() (*Config, error) {
	c := &Config{Source: map[string]string{}}
	envfile, _ := readEnvfile(EnvfilePath())
	get := func(key string) string {
		if v, ok := os.LookupEnv(key); ok && v != "" {
			c.Source[key] = "env"
			return v
		}
		if v, ok := envfile[key]; ok && v != "" {
			c.Source[key] = "envfile"
			return v
		}
		return ""
	}

	c.Agent = orDefault(get("FORGE_AGENT"), DefaultAgent)
	c.Model = orDefault(get("FORGE_MODEL"), DefaultModel)
	c.TicketsRoot = orDefault(get("FORGE_TICKETS_ROOT"), defaultTicketsRoot())
	c.AutoApprove = get("FORGE_AUTO_APPROVE") == "1"
	c.Quiet = get("FORGE_QUIET") == "1"
	c.PermissionMode = orDefault(get("FORGE_CLAUDE_PERMISSION_MODE"), "bypassPermissions")
	c.AllowedTools = get("FORGE_ALLOWED_TOOLS")
	c.ExtraDirs = get("FORGE_EXTRA_DIRS")
	c.Timeout = parseDur(get("FORGE_TIMEOUT"), 0)
	c.OpenAIBaseURL = get("OPENAI_BASE_URL")
	c.OpenAIAPIKey = get("OPENAI_API_KEY")
	c.OpenAITimeout = parseDur(get("OPENAI_TIMEOUT"), DefaultOpenAITTL)
	c.LinearAPIKey = get("LINEAR_API_KEY")
	c.ClaudeModel = orDefault(get("FORGE_CLAUDE_MODEL"), "claude-opus-4-7[1m]")
	c.ClaudeEffort = orDefault(get("FORGE_CLAUDE_EFFORT"), "max")
	c.ClaudeThinkingTok = get("FORGE_CLAUDE_THINKING_TOKENS")
	c.PromptsRoot = orDefault(get("FORGE_PROMPTS_ROOT"), defaultPromptsRoot())
	c.Repo = get("FORGE_REPO")

	return c, nil
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

func defaultTicketsRoot() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "/tmp/forge-tickets"
	}
	return filepath.Join(home, "work", "tickets")
}

func defaultPromptsRoot() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "work", "forge-prompts")
}

// parseDur accepts either Go duration (`1h`, `30s`) or a bare integer for
// seconds. Returns def on parse failure.
func parseDur(s string, def time.Duration) time.Duration {
	if s == "" {
		return def
	}
	if d, err := time.ParseDuration(s); err == nil {
		return d
	}
	if secs, err := time.ParseDuration(s + "s"); err == nil {
		return secs
	}
	return def
}

// readEnvfile parses simple KEY=value lines. Lines starting with `#` and
// blank lines are skipped. Lines containing `$(`, backticks, or starting
// with `export ` are skipped (they need shell evaluation, which forge
// won't do).
func readEnvfile(path string) (map[string]string, error) {
	out := map[string]string{}
	if path == "" {
		return out, errors.New("no envfile path")
	}
	f, err := os.Open(path)
	if err != nil {
		return out, err
	}
	defer f.Close()

	s := bufio.NewScanner(f)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "export ") || strings.Contains(line, "$(") || strings.Contains(line, "`") {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		val = strings.Trim(val, `"'`)
		out[key] = val
	}
	return out, s.Err()
}

// Redact replaces a secret with a fingerprint suitable for human-readable
// audit output: `head…tail (N chars)`.
func Redact(v string) string {
	n := len(v)
	switch {
	case n == 0:
		return "(empty)"
	case n < 8:
		return fmt.Sprintf("(%d chars)", n)
	default:
		return fmt.Sprintf("%s…%s (%d chars)", v[:4], v[n-4:], n)
	}
}
