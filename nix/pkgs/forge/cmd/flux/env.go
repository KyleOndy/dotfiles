package flux

import (
	"context"
	"fmt"
	"os/exec"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/agent"
	"github.com/kyleondy/dotfiles/forge/internal/config"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

func newEnvReal() *cobra.Command {
	c := &cobra.Command{
		Use:   "env",
		Short: "Audit forge config and run preflight for the configured agent",
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			// If --agent was set on the flux command, surface that in the
			// source annotation so the user sees where the override came from.
			if flagVal, _ := cmd.InheritedFlags().GetString(agentFlagName); flagVal != "" {
				cfg.Source["FORGE_AGENT"] = "--agent flag"
			}
			fmt.Println("forge env audit")
			fmt.Printf("(envfile: %s)\n\n", config.EnvfilePath())

			fmt.Println("agent:")
			showVal("FORGE_AGENT", cfg.Agent, cfg.Source)
			showVal("FORGE_MODEL", cfg.Model, cfg.Source)
			showVal("FORGE_TICKETS_ROOT", cfg.TicketsRoot, cfg.Source)
			fmt.Println()

			fmt.Println("pi:")
			showVal("OPENAI_BASE_URL", cfg.OpenAIBaseURL, cfg.Source)
			showSecret("OPENAI_API_KEY", cfg.OpenAIAPIKey, cfg.Source)
			showVal("OPENAI_TIMEOUT", cfg.OpenAITimeout.String(), cfg.Source)
			fmt.Println()

			fmt.Println("claude:")
			showVal("FORGE_CLAUDE_MODEL", cfg.ClaudeModel, cfg.Source)
			showVal("FORGE_CLAUDE_PERMISSION_MODE", cfg.PermissionMode, cfg.Source)
			fmt.Println()

			fmt.Println("linear:")
			showSecret("LINEAR_API_KEY", cfg.LinearAPIKey, cfg.Source)
			fmt.Println()

			fmt.Println("tools on PATH:")
			fmt.Print("  ")
			for _, t := range []string{"claude", "pi", "curl", "jq", "gh", "linear", "git"} {
				if _, err := exec.LookPath(t); err == nil {
					fmt.Printf("%s%s ✓%s  ", ui.Color("green"), t, ui.Color("reset"))
				} else {
					fmt.Printf("%s%s ✗%s  ", ui.Color("red"), t, ui.Color("reset"))
				}
			}
			fmt.Print("\n\n")

			// Run preflight against the configured backend.
			r := buildRouter(cfg)
			fmt.Println("verdict:")
			if err := r.Default.Preflight(context.Background()); err != nil {
				ui.L().Error("%s preflight: %v", r.Default.Name(), err)
				return fmt.Errorf("preflight failed for %s", r.Default.Name())
			}
			ui.L().Info("OK — %s has everything it needs", r.Default.Name())
			// Tool-capable phases swap to a different backend; preflight
			// that one too so the user sees both verdicts.
			b, err := r.Pick(agent.PhaseBuilder)
			if err != nil {
				ui.L().Warn("builder/critic dispatch unavailable: %v", err)
				return nil
			}
			if b.Name() != r.Default.Name() {
				if err := b.Preflight(context.Background()); err != nil {
					ui.L().Error("%s preflight (builder/critic): %v", b.Name(), err)
					return fmt.Errorf("preflight failed for %s", b.Name())
				}
				ui.L().Info("OK — %s also ready (used for builder/critic)", b.Name())
			}
			return nil
		},
	}
	return c
}

func showVal(name, val string, src map[string]string) {
	if val == "" {
		fmt.Printf("  %-20s (unset)\n", name)
		return
	}
	source := ""
	if s, ok := src[name]; ok {
		source = " (" + s + ")"
	}
	fmt.Printf("  %-20s %s%s\n", name, val, source)
}

func showSecret(name, val string, src map[string]string) {
	if val == "" {
		fmt.Printf("  %-20s UNSET\n", name)
		return
	}
	source := ""
	if s, ok := src[name]; ok {
		source = " (" + s + ")"
	}
	fmt.Printf("  %-20s SET   %s%s\n", name, config.Redact(val), source)
}
