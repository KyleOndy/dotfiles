package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadDefaults(t *testing.T) {
	t.Setenv("FORGE_AGENT", "")
	t.Setenv("FORGE_MODEL", "")
	t.Setenv("FORGE_TICKETS_ROOT", "")
	t.Setenv("FORGE_ENV_FILE", "/no/such/file")

	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.Agent != DefaultAgent {
		t.Errorf("Agent: got %q want %q", c.Agent, DefaultAgent)
	}
	if c.Model != DefaultModel {
		t.Errorf("Model: got %q want %q", c.Model, DefaultModel)
	}
	if c.OpenAITimeout != DefaultOpenAITTL {
		t.Errorf("OpenAITimeout: got %v want %v", c.OpenAITimeout, DefaultOpenAITTL)
	}
}

func TestLoadEnvWins(t *testing.T) {
	t.Setenv("FORGE_AGENT", "claude")
	t.Setenv("FORGE_MODEL", "sonnet")
	t.Setenv("OPENAI_API_KEY", "sk-test")
	t.Setenv("FORGE_ENV_FILE", "/no/such/file")

	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.Agent != "claude" {
		t.Errorf("Agent: got %q want claude", c.Agent)
	}
	if c.Model != "sonnet" {
		t.Errorf("Model: got %q want sonnet", c.Model)
	}
	if c.OpenAIAPIKey != "sk-test" {
		t.Errorf("OpenAIAPIKey: got %q want sk-test", c.OpenAIAPIKey)
	}
	if c.Source["FORGE_AGENT"] != "env" {
		t.Errorf("Source FORGE_AGENT: got %q want env", c.Source["FORGE_AGENT"])
	}
}

func TestLoadEnvfileFallback(t *testing.T) {
	dir := t.TempDir()
	envfile := filepath.Join(dir, "env")
	const content = `# defaults
FORGE_AGENT=pi
FORGE_MODEL=kimi-k2.5
OPENAI_BASE_URL="https://example.com/v1"

# secrets via shell only — these should be skipped:
export OPENAI_API_KEY=$(pass show openai)
LINEAR_API_KEY=` + "`" + `cat ~/.secret` + "`" + `
`
	if err := writeFile(envfile, content); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FORGE_ENV_FILE", envfile)
	t.Setenv("FORGE_AGENT", "")
	t.Setenv("FORGE_MODEL", "")
	t.Setenv("OPENAI_BASE_URL", "")
	t.Setenv("OPENAI_API_KEY", "")
	t.Setenv("LINEAR_API_KEY", "")

	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.Agent != "pi" {
		t.Errorf("Agent: got %q want pi", c.Agent)
	}
	if c.OpenAIBaseURL != "https://example.com/v1" {
		t.Errorf("OpenAIBaseURL: got %q", c.OpenAIBaseURL)
	}
	if c.OpenAIAPIKey != "" {
		t.Errorf("OpenAIAPIKey: should be empty (line was shell-evaluated); got %q", c.OpenAIAPIKey)
	}
	if c.LinearAPIKey != "" {
		t.Errorf("LinearAPIKey: should be empty (backticks); got %q", c.LinearAPIKey)
	}
	if c.Source["FORGE_AGENT"] != "envfile" {
		t.Errorf("Source FORGE_AGENT: got %q want envfile", c.Source["FORGE_AGENT"])
	}
}

func TestRedact(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"", "(empty)"},
		{"abc", "(3 chars)"},
		{"sk-1234567890", "sk-1…7890 (13 chars)"},
	}
	for _, c := range cases {
		if got := Redact(c.in); got != c.want {
			t.Errorf("Redact(%q): got %q want %q", c.in, got, c.want)
		}
	}
}

func writeFile(path, content string) error {
	return os.WriteFile(path, []byte(content), 0o644)
}
