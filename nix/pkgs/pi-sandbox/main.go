package main

import (
	"context"
	"flag"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/creack/pty"
)

func main() {
	fs := flag.NewFlagSet("pi-sandbox", flag.ExitOnError)
	baseURL := fs.String("base-url", "", "base URL for a custom OpenAI-compatible provider")
	apiKey := fs.String("api-key", "", "API key for custom provider")
	noSandbox := fs.Bool("no-sandbox", false, "skip agent-sandbox and run pi directly (no isolation)")
	timeout := fs.Duration("timeout", 0, "per-iteration timeout (e.g. 30m, 1h); 0 means no timeout")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: pi-sandbox [flags] <model> <prompt>")
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintln(os.Stderr, "  model   ollama tag (llama3.1:8b), openrouter model (org/model), or configured provider (provider/org/model)")
		fmt.Fprintln(os.Stderr, "  prompt  task to give pi (quote it)")
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintln(os.Stderr, "flags:")
		fs.PrintDefaults()
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprintln(os.Stderr, "openrouter models require OPENROUTER_API_KEY in the environment")
		fmt.Fprintf(os.Stderr, "configured providers: see %s\n", providersConfigPath())
	}
	fs.Parse(os.Args[1:])

	args := fs.Args()
	if len(args) < 2 {
		fs.Usage()
		os.Exit(2)
	}

	model := args[0]
	prompt := strings.Join(args[1:], " ")

	code, err := run(model, prompt, *baseURL, *apiKey, *noSandbox, *timeout)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[pi-sandbox] error: %v\n", err)
		os.Exit(1)
	}
	os.Exit(code)
}

func resolveProvider(model string) (string, *providerDef, error) {
	if !strings.Contains(model, "/") {
		return "ollama", nil, nil
	}

	prefix, _, _ := strings.Cut(model, "/")

	providers, err := loadProvidersConfig()
	if err != nil {
		return "", nil, err
	}
	if def, ok := providers[prefix]; ok {
		if os.Getenv(def.APIKeyEnv) == "" {
			return "", nil, fmt.Errorf("%s must be set for %s models", def.APIKeyEnv, prefix)
		}
		return prefix, &def, nil
	}

	if os.Getenv("OPENROUTER_API_KEY") == "" {
		return "", nil, fmt.Errorf("OPENROUTER_API_KEY must be set for openrouter models")
	}
	return "openrouter", nil, nil
}

func run(model, prompt, baseURL, apiKey string, noSandbox bool, timeout time.Duration) (int, error) {
	var provider string
	var def *providerDef

	if baseURL != "" {
		provider = "custom"
		def = &providerDef{BaseURL: baseURL, apiKey: apiKey}
	} else {
		var err error
		provider, def, err = resolveProvider(model)
		if err != nil {
			return 1, err
		}
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

	return runOnce(model, provider, def, prompt, workDir, 0, noSandbox, timeout)
}

// runOnce executes a single pi agent session in the sandbox.
// When iteration > 0, log files are numbered (events.N.jsonl, sandbox.N.log).
func runOnce(model, provider string, def *providerDef, prompt, workDir string, iteration int, noSandbox bool, timeout time.Duration) (int, error) {
	cfgDir, err := createConfigDir(provider, model, def)
	if err != nil {
		return 1, err
	}
	defer os.RemoveAll(cfgDir)

	fullPrompt := prompt + "\n\n" +
		"If you need a tool that is not already installed, use " +
		"`nix-shell -p <package> --run '<command>'` to run it. " +
		"Multiple packages: `nix-shell -p pkg1 -p pkg2 --run '<command>'`."

	piModel := model
	if def != nil {
		piModel = strings.TrimPrefix(model, provider+"/")
	}

	piArgs := []string{
		"--mode", "json",
		"--provider", provider,
		"--model", piModel,
		"--no-session", "--no-skills", "--no-extensions",
		"-p", fullPrompt,
	}

	ctx := context.Background()
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}

	var cmd *exec.Cmd
	if noSandbox {
		// bubblewrap uses Linux user namespaces and network namespaces. macOS has
		// neither, and no viable equivalent exists. We run pi directly with no
		// filesystem isolation, no network allow-listing, and no process containment.
		// We wish we didn't have to do this.
		cmd = exec.CommandContext(ctx, "pi", piArgs...)
		cmd.Env = append(os.Environ(), "PI_CODING_AGENT_DIR="+cfgDir)
	} else {
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
		case "ollama":
			sandboxArgs = append(sandboxArgs,
				"--net=allow:127.0.0.1:11434",
			)
		default:
			u, err := url.Parse(def.BaseURL)
			if err != nil {
				return 1, fmt.Errorf("parse base URL for %s: %w", provider, err)
			}
			port := u.Port()
			if port == "" {
				port = "443"
			}
			sandboxArgs = append(sandboxArgs,
				fmt.Sprintf("--net=allow:%s:%s", u.Hostname(), port),
			)
		}
		sandboxArgs = append(sandboxArgs, "--")
		sandboxArgs = append(sandboxArgs, "pi")
		sandboxArgs = append(sandboxArgs, piArgs...)
		cmd = exec.CommandContext(ctx, "agent-sandbox", sandboxArgs...)
	}
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
		if ctx.Err() == context.DeadlineExceeded {
			return 1, fmt.Errorf("iteration timed out after %v", timeout)
		}
		if exit, ok := err.(*exec.ExitError); ok {
			exitCode = exit.ExitCode()
		} else {
			return 1, fmt.Errorf("wait: %w", err)
		}
	}

	fmt.Fprintf(os.Stderr, "\n[pi-sandbox] output in: %s\n", workDir)
	return exitCode, nil
}
