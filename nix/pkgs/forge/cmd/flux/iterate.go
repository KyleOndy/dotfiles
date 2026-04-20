package flux

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/prompt"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

func newIterateReal() *cobra.Command {
	c := &cobra.Command{
		Use:   "iterate",
		Short: "Launch an interactive claude session against SPEC.md or PLAN.md",
	}
	c.AddCommand(newIterateSpec())
	c.AddCommand(newIteratePlan())
	return c
}

func newIterateSpec() *cobra.Command {
	return &cobra.Command{
		Use:               "spec <ticket>",
		Short:             "Iterate SPEC.md interactively via claude",
		Args:              cobra.ExactArgs(1),
		ValidArgsFunction: completeTicketIDs,
		RunE: func(_ *cobra.Command, args []string) error {
			id := args[0]
			cfg, l, err := requireWorkDir(id)
			if err != nil {
				return err
			}
			composed, err := prompt.ComposeIterateSpec(l, id)
			if err != nil {
				return err
			}
			return execClaudeInteractive(cfg.ClaudeModel, cfg.ClaudeEffort, cfg.ClaudeThinkingTok, l.Root, composed.Prompt)
		},
	}
}

func newIteratePlan() *cobra.Command {
	return &cobra.Command{
		Use:               "plan <ticket>",
		Short:             "Iterate PLAN.md interactively via claude",
		Args:              cobra.ExactArgs(1),
		ValidArgsFunction: completeTicketIDs,
		RunE: func(_ *cobra.Command, args []string) error {
			id := args[0]
			cfg, l, err := requireWorkDir(id)
			if err != nil {
				return err
			}
			composed, err := prompt.ComposeIteratePlan(l, id)
			if err != nil {
				return err
			}
			return execClaudeInteractive(cfg.ClaudeModel, cfg.ClaudeEffort, cfg.ClaudeThinkingTok, l.Root, composed.Prompt)
		},
	}
}

// execClaudeInteractive replaces the current process with a `claude`
// session inside dir. The bootstrap prompt is passed as a positional arg.
func execClaudeInteractive(model, effort, thinking, dir, bootstrap string) error {
	bin, err := exec.LookPath("claude")
	if err != nil {
		return fmt.Errorf("claude CLI not found on PATH")
	}
	args := []string{
		"claude",
		"--model", model,
		"--add-dir", dir,
		"--permission-mode", "acceptEdits",
		bootstrap,
	}
	env := os.Environ()
	if effort != "" {
		env = append(env, "CLAUDE_CODE_EFFORT_LEVEL="+effort)
	}
	if thinking != "" {
		env = append(env, "MAX_THINKING_TOKENS="+thinking)
	}
	if err := os.Chdir(dir); err != nil {
		return fmt.Errorf("cd %s: %w", dir, err)
	}
	ui.L().Info("launching claude in %s", dir)
	ui.L().Info("model=%s effort=%s", model, effort)
	return syscall.Exec(bin, args, env)
}
