package flux

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/linear"
	"github.com/kyleondy/dotfiles/forge/internal/ticket"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

func newLinearReal() *cobra.Command {
	c := &cobra.Command{Use: "linear", Short: "Linear integration"}
	c.AddCommand(newLinearFetch())
	return c
}

func newLinearFetch() *cobra.Command {
	return &cobra.Command{
		Use:               "fetch <ticket>",
		Short:             "Pull a Linear ticket into LINEAR.md (and LINEAR.json for debugging)",
		Args:              cobra.ExactArgs(1),
		ValidArgsFunction: completeTicketIDs,
		RunE: func(_ *cobra.Command, args []string) error {
			id := args[0]
			if !ticket.IsLinear(id) {
				ui.L().Warn("%s is not a Linear-style ID; skipping", id)
				return nil
			}
			cfg, l, err := requireTicket(id, true)
			if err != nil {
				return err
			}
			if err := preflightLinear(cfg.LinearAPIKey); err != nil {
				return err
			}

			attachmentsDir := filepath.Join(l.Root, "linear-attachments")
			if err := os.MkdirAll(attachmentsDir, 0o755); err != nil {
				return err
			}
			ui.L().Info("fetching Linear ticket %s", id)
			raw, err := linear.FetchIssueJSON(context.Background(), linear.Default(), attachmentsDir, id)
			if err != nil {
				return err
			}
			jsonPath := filepath.Join(l.Root, "LINEAR.json")
			if err := os.WriteFile(jsonPath, raw, 0o644); err != nil {
				return err
			}
			md, err := linear.IssueToMarkdown(raw)
			if err != nil {
				return err
			}
			if err := os.WriteFile(l.LinearMD, []byte(md), 0o644); err != nil {
				return err
			}
			ui.L().Info("wrote %s", l.LinearMD)
			ui.L().Info("raw:   %s", jsonPath)
			ui.L().Info("next:  forge flux spec %s", id)
			return nil
		},
	}
}

func preflightLinear(apiKey string) error {
	if err := linear.Preflight(apiKey); err != nil {
		return fmt.Errorf("%w (set LINEAR_API_KEY and install the linear CLI)", err)
	}
	return nil
}

// runLinearPost is exposed via status.go's postStatus helper so the
// Linear dependency is one place.
func runLinearPost(ctx context.Context, ticketID, body string) error {
	return linear.PostComment(ctx, linear.Default(), ticketID, body)
}
