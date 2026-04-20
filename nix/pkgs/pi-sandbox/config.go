package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type modelsConfig struct {
	Providers map[string]providerConfig `json:"providers"`
}

type providerConfig struct {
	BaseURL string       `json:"baseUrl"`
	API     string       `json:"api"`
	APIKey  string       `json:"apiKey"`
	Compat  compatConfig `json:"compat"`
	Models  []modelEntry `json:"models"`
}

type compatConfig struct {
	SupportsDeveloperRole   bool `json:"supportsDeveloperRole"`
	SupportsReasoningEffort bool `json:"supportsReasoningEffort"`
}

type modelEntry struct {
	ID string `json:"id"`
}

type providerDef struct {
	BaseURL   string `json:"baseUrl"`
	APIKeyEnv string `json:"apiKeyEnv"`
	apiKey    string // set from --api-key flag, not from config file
}

func (d *providerDef) resolveAPIKey() string {
	if d.apiKey != "" {
		return d.apiKey
	}
	return os.Getenv(d.APIKeyEnv)
}

func providersConfigPath() string {
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "pi-sandbox", "providers.json")
}

func loadProvidersConfig() (map[string]providerDef, error) {
	path := providersConfigPath()
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return map[string]providerDef{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	var cfg map[string]providerDef
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	return cfg, nil
}

func createWorkDir() (string, error) {
	dir, err := os.MkdirTemp("/tmp", "pi-sandbox-")
	if err != nil {
		return "", fmt.Errorf("create work dir: %w", err)
	}
	fmt.Fprintf(os.Stderr, "[pi-sandbox] work dir: %s\n", dir)
	return dir, nil
}

func createConfigDir(provider, model string, def *providerDef) (string, error) {
	dir, err := os.MkdirTemp("", "pi-sandbox-config-")
	if err != nil {
		return "", fmt.Errorf("create config dir: %w", err)
	}

	var provCfg providerConfig
	switch provider {
	case "openrouter":
		provCfg = providerConfig{
			BaseURL: "https://openrouter.ai/api/v1",
			API:     "openai-completions",
			Models:  []modelEntry{{ID: model}},
		}
	case "ollama":
		provCfg = providerConfig{
			BaseURL: "http://localhost:11434/v1",
			API:     "openai-completions",
			APIKey:  "ollama",
			Compat: compatConfig{
				SupportsDeveloperRole:   false,
				SupportsReasoningEffort: false,
			},
			Models: []modelEntry{{ID: model}},
		}
	default:
		provCfg = providerConfig{
			BaseURL: def.BaseURL,
			API:     "openai-completions",
			APIKey:  def.resolveAPIKey(),
			Models:  []modelEntry{{ID: strings.TrimPrefix(model, provider+"/")}},
		}
	}

	cfg := modelsConfig{
		Providers: map[string]providerConfig{
			provider: provCfg,
		},
	}

	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		os.RemoveAll(dir)
		return "", fmt.Errorf("marshal config: %w", err)
	}
	data = append(data, '\n')

	if err := os.WriteFile(filepath.Join(dir, "models.json"), data, 0644); err != nil {
		os.RemoveAll(dir)
		return "", fmt.Errorf("write models.json: %w", err)
	}

	return dir, nil
}
