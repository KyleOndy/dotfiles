package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type modelsConfig struct {
	Providers map[string]providerConfig `json:"providers"`
}

type providerConfig struct {
	BaseURL string        `json:"baseUrl"`
	API     string        `json:"api"`
	APIKey  string        `json:"apiKey"`
	Compat  compatConfig  `json:"compat"`
	Models  []modelEntry  `json:"models"`
}

type compatConfig struct {
	SupportsDeveloperRole   bool `json:"supportsDeveloperRole"`
	SupportsReasoningEffort bool `json:"supportsReasoningEffort"`
}

type modelEntry struct {
	ID string `json:"id"`
}

func createWorkDir() (string, error) {
	dir, err := os.MkdirTemp("/tmp", "pi-sandbox-")
	if err != nil {
		return "", fmt.Errorf("create work dir: %w", err)
	}
	fmt.Fprintf(os.Stderr, "[pi-sandbox] work dir: %s\n", dir)
	return dir, nil
}

func createRalphWorkDir() (string, error) {
	dir, err := os.MkdirTemp("/tmp", "pi-ralph-")
	if err != nil {
		return "", fmt.Errorf("create ralph work dir: %w", err)
	}
	fmt.Fprintf(os.Stderr, "[ralph] work dir: %s\n", dir)
	return dir, nil
}

func validateWorkDir(dir string) error {
	info, err := os.Stat(dir)
	if err != nil {
		return fmt.Errorf("work dir %s: %w", dir, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("work dir %s is not a directory", dir)
	}
	if _, err := os.Stat(filepath.Join(dir, "SPEC.md")); err != nil {
		return fmt.Errorf("work dir %s missing SPEC.md (not a ralph work dir?)", dir)
	}
	return nil
}

func createConfigDir(provider, model string) (string, error) {
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
	default:
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
