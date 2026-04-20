package flux

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/gitwt"
	"github.com/kyleondy/dotfiles/forge/internal/state"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

func newPRReal() *cobra.Command {
	return &cobra.Command{
		Use:               "pr <ticket> <task-id>",
		Short:             "Open a GitHub PR for a task's worktree branch (manual confirm)",
		Args:              cobra.ExactArgs(2),
		ValidArgsFunction: completeTicketIDs,
		RunE: func(_ *cobra.Command, args []string) error {
			id, taskID := args[0], args[1]
			cfg, l, err := requireWorkDir(id)
			if err != nil {
				return err
			}
			s, err := state.Load(l, id)
			if err != nil {
				return err
			}
			t, _ := s.Find(taskID)
			if t == nil {
				return fmt.Errorf("task %s not found", taskID)
			}

			taskDir := l.TaskDir(taskID, t.Slug)
			summaryPath := filepath.Join(taskDir, "SUMMARY.md")
			summary, err := os.ReadFile(summaryPath)
			if err != nil {
				return fmt.Errorf("no SUMMARY.md at %s; nothing to PR", summaryPath)
			}

			if t.Verdict != state.VerdictPass {
				ui.L().Warn("verdict for %s is %q; you usually want PASS before opening a PR", taskID, t.Verdict)
				if err := ui.ConfirmOrDie("Continue anyway?", cfg.AutoApprove); err != nil {
					return err
				}
			}

			ctx := context.Background()
			exe := gitwt.Default()
			cwd, _ := os.Getwd()
			wtRoot, err := gitwt.RequireRoot(ctx, exe, cwd)
			if err != nil {
				return err
			}
			worktreePath := filepath.Join(wtRoot, id, taskID+"-"+t.Slug)
			if _, err := os.Stat(worktreePath); err != nil {
				return fmt.Errorf("worktree not found: %s", worktreePath)
			}
			branch, err := gitwt.CurrentBranch(ctx, exe, worktreePath)
			if err != nil {
				return err
			}
			ui.L().Info("branch: %s", branch)

			draftDir, err := os.MkdirTemp("", "forge-pr-")
			if err != nil {
				return err
			}
			defer os.RemoveAll(draftDir)
			body := fmt.Sprintf(
				"## Summary\n\n%s\n\n## Task\n\n- Task ID: %s\n- Verdict: %s\n\n## Details\n\n%s\n",
				t.Title, taskID, t.Verdict, string(summary),
			)
			combined := filepath.Join(draftDir, "draft.md")
			combinedContent := fmt.Sprintf("# Title\n\n%s %s\n\n# Body\n\n%s\n", id, t.Title, body)
			if err := os.WriteFile(combined, []byte(combinedContent), 0o644); err != nil {
				return err
			}
			editor := os.Getenv("EDITOR")
			if editor == "" {
				editor = "vi"
			}
			ui.L().Info("opening %s in $EDITOR for review", combined)
			ed := exec.Command(editor, combined)
			ed.Stdin, ed.Stdout, ed.Stderr = os.Stdin, os.Stdout, os.Stderr
			if err := ed.Run(); err != nil {
				return err
			}
			finalTitle, finalBody, err := splitDraft(combined)
			if err != nil {
				return err
			}
			if finalTitle == "" {
				return fmt.Errorf("title is empty after edit")
			}

			fmt.Println()
			ui.L().Info("Final title: %s", finalTitle)
			fmt.Println("Final body:")
			for _, line := range strings.Split(finalBody, "\n") {
				fmt.Println("  | " + line)
			}
			fmt.Println()
			if err := ui.ConfirmOrDie("Push branch and open PR?", cfg.AutoApprove); err != nil {
				return err
			}

			if _, err := exec.LookPath("gh"); err != nil {
				return fmt.Errorf("gh CLI is required to open a PR")
			}
			ui.L().Info("pushing %s", branch)
			push := exec.Command("git", "-C", worktreePath, "push", "-u", "origin", branch)
			push.Stdout, push.Stderr = os.Stdout, os.Stderr
			if err := push.Run(); err != nil {
				return err
			}

			bodyPath := filepath.Join(draftDir, "body.md")
			if err := os.WriteFile(bodyPath, []byte(finalBody), 0o644); err != nil {
				return err
			}
			remote := exec.Command("git", "-C", worktreePath, "remote", "get-url", "origin")
			remoteOut, err := remote.Output()
			if err != nil {
				return fmt.Errorf("git remote get-url: %w", err)
			}
			remoteURL := strings.TrimSpace(string(remoteOut))
			gh := exec.Command("gh", "-R", remoteURL, "pr", "create",
				"--title", finalTitle,
				"--body-file", bodyPath,
				"--head", branch,
			)
			gh.Stdout, gh.Stderr = os.Stdout, os.Stderr
			return gh.Run()
		},
	}
}

func splitDraft(path string) (title, body string, err error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", "", err
	}
	mode := ""
	titleLines := []string{}
	bodyLines := []string{}
	for _, line := range strings.Split(string(b), "\n") {
		switch strings.TrimSpace(line) {
		case "# Title":
			mode = "title"
			continue
		case "# Body":
			mode = "body"
			continue
		}
		switch mode {
		case "title":
			if strings.TrimSpace(line) != "" {
				titleLines = append(titleLines, strings.TrimSpace(line))
			}
		case "body":
			bodyLines = append(bodyLines, line)
		}
	}
	if len(titleLines) > 0 {
		title = titleLines[0]
	}
	body = strings.TrimSpace(strings.Join(bodyLines, "\n"))
	return title, body, nil
}
