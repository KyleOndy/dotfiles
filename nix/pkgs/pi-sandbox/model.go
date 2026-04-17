package main

import (
	"fmt"
	"os"
	"os/exec"
)

func ensureModel(model string) error {
	check := exec.Command("ollama", "show", model)
	check.Stdout = nil
	check.Stderr = nil
	if check.Run() == nil {
		fmt.Fprintf(os.Stderr, "[pi-sandbox] model ready: %s\n", model)
		return nil
	}

	fmt.Fprintf(os.Stderr, "[pi-sandbox] pulling model: %s\n", model)
	pull := exec.Command("ollama", "pull", model)
	pull.Stdout = os.Stderr
	pull.Stderr = os.Stderr
	if err := pull.Run(); err != nil {
		return fmt.Errorf("ollama pull %s: %w", model, err)
	}
	return nil
}
