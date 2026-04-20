package flux

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/lock"
	"github.com/kyleondy/dotfiles/forge/internal/state"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

func newShowReal() *cobra.Command {
	return &cobra.Command{
		Use:               "show <ticket>",
		Short:             "Print a one-screen dashboard for a ticket (read-only)",
		Args:              cobra.ExactArgs(1),
		ValidArgsFunction: completeTicketIDs,
		RunE: func(_ *cobra.Command, args []string) error {
			id := args[0]
			_, l, err := requireWorkDir(id)
			if err != nil {
				return err
			}
			s, err := state.Load(l, id)
			if err != nil {
				return err
			}
			phase := state.DerivePhase(l, s)

			fmt.Printf("\n%sTicket: %s%s\n", ui.Color("bold"), id, ui.Color("reset"))
			fmt.Printf("Path:   %s\n", l.Root)
			fmt.Printf("Phase:  %s\n\n", phase)

			fmt.Println("Artifacts:")
			for _, a := range []struct{ name, path string }{
				{"SPEC.md", l.SpecPath},
				{"PLAN.md", l.PlanPath},
				{"TASKS.md", l.Root + "/TASKS.md"},
				{"DECISIONS.md", l.DecPath},
				{"LINEAR.md", l.LinearMD},
			} {
				printArtifact(a.name, a.path)
			}
			fmt.Println()

			if len(s.Tasks) > 0 {
				fmt.Println("Tasks:")
				fmt.Printf("  %-7s %-7s %-7s %-22s %s\n", "STATE", "CRITIC", "ARCH", "ID + SLUG", "TITLE")
				for _, t := range s.Tasks {
					critic := string(t.Verdict)
					if critic == "" {
						critic = "-"
					}
					arch := string(t.ArchVerdict)
					if arch == "" {
						arch = "-"
					}
					fmt.Printf("  %-7s %s%-7s%s %s%-7s%s %-22s %s\n",
						t.Status,
						verdictColor(t.Verdict), critic, ui.Color("reset"),
						verdictColor(t.ArchVerdict), arch, ui.Color("reset"),
						t.ID+" "+t.Slug, t.Title)
				}
				fmt.Println()
			}

			locks, _ := lock.All(l.LocksDir)
			if len(locks) > 0 {
				fmt.Println("Locks:")
				for _, lk := range locks {
					if lk.Alive {
						fmt.Printf("  %s● %s%s (PID %d)\n", ui.Color("green"), ui.Color("reset"), lk.Name, lk.Meta.PID)
					} else {
						fmt.Printf("  %s⚠ %s%s (PID %d, stale)\n", ui.Color("yellow"), ui.Color("reset"), lk.Name, lk.Meta.PID)
					}
				}
				fmt.Println()
			}

			if s.NeedsHuman != nil {
				fmt.Printf("%sNeeds human:%s %s\n", ui.Color("yellow"), ui.Color("reset"), s.NeedsHuman.Reason)
				if s.NeedsHuman.TaskID != "" {
					fmt.Printf("  task: %s\n", s.NeedsHuman.TaskID)
				}
				fmt.Println()
			}

			fmt.Println("Next:")
			printNextAction(id, l, s, phase)
			fmt.Println()
			return nil
		},
	}
}

func verdictColor(v state.Verdict) string {
	switch v {
	case state.VerdictPass:
		return ui.Color("green")
	case state.VerdictFail:
		return ui.Color("red")
	}
	return ""
}

func printArtifact(name, path string) {
	st, err := os.Stat(path)
	if err != nil {
		fmt.Printf("  %s· %s%-15s (missing)\n", ui.Color("red"), ui.Color("reset"), name)
		return
	}
	if st.Size() == 0 {
		fmt.Printf("  %s∅ %s%-15s (empty)\n", ui.Color("yellow"), ui.Color("reset"), name)
		return
	}
	fmt.Printf("  %s✓ %s%-15s (%d bytes)\n", ui.Color("green"), ui.Color("reset"), name, st.Size())
}

func printNextAction(id string, l state.Layout, s *state.State, phase state.Phase) {
	switch phase {
	case state.PhaseInit:
		fmt.Printf("  forge flux spec %s \"<freeform description>\"\n", id)
	case state.PhaseSpec:
		fmt.Printf("  forge flux spec %s \"<freeform description>\"   # populate via agent\n", id)
		fmt.Printf("  forge flux iterate spec %s                       # iterate interactively\n", id)
		fmt.Printf("  edit %s manually, then forge flux plan %s\n", l.SpecPath, id)
	case state.PhasePlan:
		fmt.Printf("  edit %s, then:\n", l.PlanPath)
		fmt.Printf("  forge flux decompose %s\n", id)
	case state.PhaseDecompose:
		fmt.Printf("  forge flux decompose %s\n", id)
	case state.PhaseTasks:
		if a := s.NextArchitect(); a != nil {
			fmt.Printf("  forge flux architect %s %s # critic PASS awaits architect review\n", id, a.ID)
		} else if n := s.NextPending(); n != nil {
			fmt.Printf("  forge flux task %s %s   # %s\n", id, n.ID, n.Title)
			fmt.Printf("  forge flux verify %s %s # after builder finishes\n", id, n.ID)
		}
	case state.PhaseComplete:
		fmt.Printf("  forge flux status %s        # draft today's status\n", id)
		fmt.Printf("  forge flux status post %s   # post to Linear (manual confirm)\n", id)
	}
}
