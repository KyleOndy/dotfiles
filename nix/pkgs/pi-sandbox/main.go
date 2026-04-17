package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/creack/pty"
)

func main() {
	if len(os.Args) >= 2 && os.Args[1] == "ralph" {
		os.Exit(mainRalph())
	}

	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: pi-sandbox <model> <prompt>")
		fmt.Fprintln(os.Stderr, "       pi-sandbox ralph <model> <spec-file> [flags]")
		fmt.Fprintln(os.Stderr, "       pi-sandbox ralph spec <model> <description> [-o spec.md]")
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintln(os.Stderr, "  model   ollama tag (llama3.1:8b) or openrouter model (openrouter/...)")
		fmt.Fprintln(os.Stderr, "  prompt  task to give pi (quote it)")
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintln(os.Stderr, "openrouter models require OPENROUTER_API_KEY in the environment")
		os.Exit(2)
	}

	model := os.Args[1]
	prompt := strings.Join(os.Args[2:], " ")

	code, err := run(model, prompt)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[pi-sandbox] error: %v\n", err)
		os.Exit(1)
	}
	os.Exit(code)
}

func resolveProvider(model string) (string, error) {
	// Ollama models use "name:tag" (no slash). OpenRouter models
	// always have "org/model" with a slash.
	if strings.Contains(model, "/") {
		if os.Getenv("OPENROUTER_API_KEY") == "" {
			return "", fmt.Errorf("OPENROUTER_API_KEY must be set for openrouter models")
		}
		return "openrouter", nil
	}
	return "ollama", nil
}

func run(model, prompt string) (int, error) {
	provider, err := resolveProvider(model)
	if err != nil {
		return 1, err
	}

	if provider == "ollama" {
		if err := ensureModel(model); err != nil {
			return 1, err
		}
	}

	workDir, err := createWorkDir()
	if err != nil {
		return 1, err
	}

	return runOnce(model, provider, prompt, workDir, 0)
}

// runOnce executes a single pi agent session in the sandbox.
// When iteration > 0, log files are numbered (events.N.jsonl, sandbox.N.log).
func runOnce(model, provider, prompt, workDir string, iteration int) (int, error) {
	cfgDir, err := createConfigDir(provider, model)
	if err != nil {
		return 1, err
	}
	defer os.RemoveAll(cfgDir)

	sandboxArgs := []string{
		"--bind=" + cfgDir,
		"--bind=/nix/var/nix/daemon-socket",
		"--env=PI_CODING_AGENT_DIR=" + cfgDir,
		"--env=NIX_PATH",
	}
	switch provider {
	case "openrouter":
		sandboxArgs = append(sandboxArgs,
			"--net=allow:openrouter.ai:443",
			"--env=OPENROUTER_API_KEY",
		)
	default:
		sandboxArgs = append(sandboxArgs,
			"--net=allow:127.0.0.1:11434",
		)
	}

	fullPrompt := prompt + "\n\n" +
		"If you need a tool that is not already installed, use " +
		"`nix-shell -p <package> --run '<command>'` to run it. " +
		"Multiple packages: `nix-shell -p pkg1 -p pkg2 --run '<command>'`."

	sandboxArgs = append(sandboxArgs, "--",
		"pi",
		"--mode", "json",
		"--provider", provider,
		"--model", model,
		"--no-session", "--no-skills", "--no-extensions",
		"-p", fullPrompt,
	)

	cmd := exec.Command("agent-sandbox", sandboxArgs...)
	cmd.Dir = workDir

	// Name log files with iteration number when running in a loop.
	logName := "sandbox.log"
	eventName := "events.jsonl"
	if iteration > 0 {
		logName = fmt.Sprintf("sandbox.%d.log", iteration)
		eventName = fmt.Sprintf("events.%d.jsonl", iteration)
	}

	logFile, err := os.Create(filepath.Join(workDir, logName))
	if err != nil {
		return 1, fmt.Errorf("create log: %w", err)
	}
	defer logFile.Close()
	cmd.Stderr = logFile

	eventLog, err := os.Create(filepath.Join(workDir, eventName))
	if err != nil {
		return 1, fmt.Errorf("create event log: %w", err)
	}
	defer eventLog.Close()

	ptm, err := pty.Start(cmd)
	if err != nil {
		return 1, fmt.Errorf("pty start: %w", err)
	}
	defer ptm.Close()

	streamEvents(ptm, eventLog)

	exitCode := 0
	if err := cmd.Wait(); err != nil {
		if exit, ok := err.(*exec.ExitError); ok {
			exitCode = exit.ExitCode()
		} else {
			return 1, fmt.Errorf("wait: %w", err)
		}
	}

	fmt.Fprintf(os.Stderr, "\n[pi-sandbox] output in: %s\n", workDir)
	return exitCode, nil
}
