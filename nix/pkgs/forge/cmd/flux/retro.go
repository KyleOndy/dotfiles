package flux

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/agent"
	"github.com/kyleondy/dotfiles/forge/internal/config"
	"github.com/kyleondy/dotfiles/forge/internal/events"
	"github.com/kyleondy/dotfiles/forge/internal/lock"
	"github.com/kyleondy/dotfiles/forge/internal/prompt"
	"github.com/kyleondy/dotfiles/forge/internal/state"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

func newRetroReal() *cobra.Command {
	return &cobra.Command{
		Use:               "retro <ticket>",
		Short:             "Retrospective phase: distill ticket's review findings into durable rules",
		Args:              cobra.ExactArgs(1),
		ValidArgsFunction: completeTicketIDs,
		RunE: func(cmd *cobra.Command, args []string) error {
			id := args[0]
			cfg, l, err := requireWorkDir(id)
			if err != nil {
				return err
			}
			s, err := state.Load(l, id)
			if err != nil {
				return err
			}
			if !s.AllTasksDone() {
				return fmt.Errorf("retro requires every task done with critic PASS and architect PASS")
			}

			targetPath, err := retroTargetPath(cfg)
			if err != nil {
				return err
			}
			if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
				return fmt.Errorf("mkdir prompts dir: %w", err)
			}
			ui.L().Info("retro target: %s", targetPath)

			lk, err := lock.Acquire(l.LocksDir, "retro", id)
			if err != nil {
				return err
			}
			defer lk.Release()

			composed, err := prompt.ComposeRetro(l, s, id, targetPath, time.Now().Format("2006-01-02"))
			if err != nil {
				return err
			}
			composed.Prompt = phaseOverrides(cfg, "retro").Apply(composed.Prompt)

			eventPath := events.Path(l.EventsDir, "retro", id)
			eventLog, err := events.Open(eventPath)
			if err != nil {
				return err
			}
			defer eventLog.Close()
			ui.L().Info("event log: %s", eventPath)

			ctx := context.Background()
			req := agent.Request{
				Prompt:       composed.Prompt,
				Phase:        agent.PhaseRetro,
				TicketID:     id,
				CWD:          l.Root,
				ExtraDirs:    []string{filepath.Dir(targetPath)},
				AllowedTools: []string{"Write", "Edit", "Read"},
				Quiet:        cfg.Quiet,
				EventLog:     eventLog,
				Stdout:       cmd.OutOrStdout(),
				Stderr:       cmd.ErrOrStderr(),
				Timeout:      cfg.OpenAITimeout,
			}
			if _, err := dispatchAgent(ctx, cfg, req); err != nil {
				return err
			}
			ui.L().Info("retro complete; rules at %s", targetPath)
			ui.L().Info("next: git diff %s  (review before keeping)", targetPath)
			return nil
		},
	}
}

// retroTargetPath resolves the repo-scoped common-suffix override file the
// retrospective writes to. Mirrors prompt.LoadOverrides path layout so the
// builder/critic/architect pick it up on future tickets automatically.
func retroTargetPath(cfg *config.Config) (string, error) {
	if cfg.PromptsRoot == "" {
		return "", fmt.Errorf("FORGE_PROMPTS_ROOT not set; retro needs a prompts root to write to")
	}
	repo := cfg.Repo
	if repo == "" {
		cwd, _ := os.Getwd()
		repo = prompt.DetectRepo(cwd)
	}
	if repo == "" {
		return "", fmt.Errorf("could not resolve repo key for retro target; set FORGE_REPO")
	}
	return filepath.Join(cfg.PromptsRoot, repo, "_common.suffix.md"), nil
}
