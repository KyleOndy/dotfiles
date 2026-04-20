// Package flux is the agent-orchestration subcommand tree.
//
// `forge flux` drives the spec → plan → decompose → loop(task → verify)
// agentic loop for ticket-scoped work.
package flux

import (
	"os"

	"github.com/spf13/cobra"
)

// agentFlag is set by the root `flux` command's PersistentPreRunE when the
// user passes `--agent`. We stash it in a process-scoped env var so the
// existing config.Load() machinery picks it up uniformly alongside
// FORGE_AGENT from the shell — no plumbing change needed downstream.
const agentFlagName = "agent"

func New() *cobra.Command {
	c := &cobra.Command{
		Use:   "flux",
		Short: "Agent orchestration loop for ticket-scoped work",
		PersistentPreRunE: func(cmd *cobra.Command, _ []string) error {
			v, err := cmd.Flags().GetString(agentFlagName)
			if err != nil || v == "" {
				return nil
			}
			return os.Setenv("FORGE_AGENT", v)
		},
		Long: `Drive the spec → plan → decompose → task → verify loop for a ticket.

State lives under ~/work/tickets/<TICKET>/ (configurable via FORGE_TICKETS_ROOT).
Machine state in .forge/state.json; human artifacts (SPEC.md, PLAN.md,
SUMMARY.md, REVIEW.md, DECISIONS.md, LINEAR.md) live alongside.

Pipeline:

     init ─► spec ─► plan ─► decompose ─┐
              ▲       ▲                 │
              │       │                 ▼
          iterate  iterate       ┌──► task ──► verify ──► architect ─► pr
            spec    plan         │              │             │
                                 │              ▼ FAIL        ▼ FAIL
                                 └──── reset ◄──┴─────────────┘
                                    PASS + PASS ─► (next task) ─► retro

Phases:
  init       scaffold ticket dir + state.json
  spec       draft SPEC.md from ticket description (LINEAR.md auto-fetched)
  plan       generate PLAN.md from SPEC.md
  decompose  split PLAN.md into TASKS.md + per-task PLAN.md files
  task       builder agent implements one task in its own worktree
  verify     critic agent reviews the diff, writes VERDICT + REVIEW.md
  architect  architect agent checks codebase-fit, writes ARCH_VERDICT + ARCHITECT.md
  retro      distill ticket's review findings into durable rules (repo-scoped suffix)
  pr         open a GitHub PR for a PASSed task (manual confirm)

Iterating:
  iterate spec <ticket>   interactive claude on SPEC.md
  iterate plan <ticket>   interactive claude on PLAN.md
  reset <ticket> [task]   clear FAIL + retry counter; keep accumulated
                          critic feedback so the next task run sees it
  reset --hard            also drop the per-task PLAN.md feedback

Drivers and visibility:
  auto <ticket>           run the full pipeline until done or retry cap
  show <ticket>           one-screen dashboard (phase, tasks, locks)
  resume <ticket>         dashboard; with --auto, continue the loop
  status <ticket>         draft today's status update (status post = publish)
  env                     audit config + preflight the configured agent`,
	}
	c.PersistentFlags().String(agentFlagName, "", "Override FORGE_AGENT for this invocation (pi|claude)")
	c.AddCommand(
		newInitReal(),
		newSpecReal(),
		newPlanReal(),
		newDecomposeReal(),
		newTaskReal(),
		newVerifyReal(),
		newArchitectReal(),
		newRetroReal(),
		newAutoReal(),
		newShowReal(),
		newStatusReal(),
		newPRReal(),
		newResetReal(),
		newResumeReal(),
		newEnvReal(),
		newIterateReal(),
		newLinearReal(),
		newAgentReal(),
	)
	return c
}
