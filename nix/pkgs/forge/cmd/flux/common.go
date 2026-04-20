package flux

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/kyleondy/dotfiles/forge/internal/agent"
	"github.com/kyleondy/dotfiles/forge/internal/config"
	"github.com/kyleondy/dotfiles/forge/internal/linear"
	"github.com/kyleondy/dotfiles/forge/internal/prompt"
	"github.com/kyleondy/dotfiles/forge/internal/state"
	"github.com/kyleondy/dotfiles/forge/internal/ticket"
	"github.com/kyleondy/dotfiles/forge/internal/ui"
)

// phaseOverrides loads repo-keyed prompt overrides for a given phase. Repo
// resolution: cfg.Repo (FORGE_REPO) > git toplevel basename > cwd basename.
// Returns an empty Overrides when nothing applies. When files contributed,
// logs which ones via ui.L().Info — useful trail when debugging a prompt.
func phaseOverrides(cfg *config.Config, phase string) prompt.Overrides {
	if cfg == nil || cfg.PromptsRoot == "" {
		return prompt.Overrides{}
	}
	repo := cfg.Repo
	if repo == "" {
		cwd, _ := os.Getwd()
		repo = prompt.DetectRepo(cwd)
	}
	if repo == "" {
		return prompt.Overrides{}
	}
	ov := prompt.LoadOverrides(cfg.PromptsRoot, repo, phase)
	if len(ov.Sources) > 0 {
		ui.L().Info("prompt overrides (%s): %s", phase, strings.Join(ov.Sources, ", "))
	}
	return ov
}

// completionCacheTTL bounds how old the Linear cache may be before a
// background refresh is kicked off on TAB. 10 minutes keeps completions
// fresh enough for an active workday without hammering the API.
const completionCacheTTL = 10 * time.Minute

// completeTicketIDs is the ValidArgsFunction for any flux command whose
// arg[0] is a ticket ID. It reads the Linear assigned-to-me cache and
// returns "IDENT\t[tags] Title" lines so zsh/fish show context as a
// description column (bash ignores everything after the tab). When the
// cache is missing or stale, a detached `forge tickets refresh` is fired
// and the current call returns whatever is in the cache already (possibly
// nothing). TAB must never block on the network.
//
// Commands whose arg[0] is a ticket ID register:
//
//	ValidArgsFunction: completeTicketIDs
func completeTicketIDs(_ *cobra.Command, args []string, toComplete string) ([]string, cobra.ShellCompDirective) {
	if len(args) > 0 {
		return nil, cobra.ShellCompDirectiveNoFileComp
	}
	cache, err := linear.ReadCache()
	stale := err != nil || time.Since(cache.FetchedAt) > completionCacheTTL
	if stale {
		spawnBackgroundRefresh()
	}
	if err != nil {
		return nil, cobra.ShellCompDirectiveNoFileComp | cobra.ShellCompDirectiveKeepOrder
	}
	linear.SortByIDAsc(cache.Issues)
	ticketsRoot := ""
	if cfg, err := config.Load(); err == nil {
		ticketsRoot = cfg.TicketsRoot
	}
	prefix := strings.ToUpper(toComplete)
	out := make([]string, 0, len(cache.Issues))
	for _, iss := range cache.Issues {
		if prefix != "" && !strings.HasPrefix(strings.ToUpper(iss.Identifier), prefix) {
			continue
		}
		desc := formatCompletionDesc(iss, ticketsRoot)
		out = append(out, iss.Identifier+"\t"+desc)
	}
	return out, cobra.ShellCompDirectiveNoFileComp | cobra.ShellCompDirectiveKeepOrder
}

// formatCompletionDesc builds the "[tags] Title" description column for
// one cached ticket. Tags are omitted when they don't apply:
//
//   - priority "Pn" — skipped when no priority is set
//   - Linear status name — always shown when available
//   - flux workflow phase — only when a local workspace exists
//
// When ticketsRoot is empty (config unreadable) the flux phase is skipped.
func formatCompletionDesc(iss linear.AssignedIssue, ticketsRoot string) string {
	tags := make([]string, 0, 3)
	if label := priorityLabel(iss.Priority); label != "" {
		tags = append(tags, label)
	}
	status := iss.StateName
	if status == "" {
		status = iss.StateType
	}
	if status != "" {
		tags = append(tags, status)
	}
	if phase := ticketFluxPhase(ticketsRoot, iss.Identifier); phase != "" {
		// " · " separates Linear status from local flux phase so it's clear
		// which side of the tag is Linear's and which is forge's.
		if len(tags) == 0 {
			tags = append(tags, phase)
		} else {
			tags[len(tags)-1] = tags[len(tags)-1] + " · " + phase
		}
	}
	if len(tags) == 0 {
		return iss.Title
	}
	return "[" + strings.Join(tags, " ") + "] " + iss.Title
}

// priorityLabel renders Linear's 1..4 priority as "P1".."P4". Priority 0
// ("No priority") renders as empty.
func priorityLabel(p int) string {
	if p < 1 || p > 4 {
		return ""
	}
	return "P" + strconv.Itoa(p)
}

// ticketFluxPhase returns a short label for the local flux phase when a
// workspace exists for the ticket. Returns "" when the ticket has no
// workspace yet. Must be cheap — fires for every cached ticket on TAB.
func ticketFluxPhase(ticketsRoot, ticketID string) string {
	if ticketsRoot == "" {
		return ""
	}
	l := state.LayoutFor(ticketsRoot, ticketID)
	if _, err := os.Stat(l.ForgeDir); err != nil {
		return ""
	}
	s, err := state.Load(l, ticketID)
	if err != nil {
		return ""
	}
	phase := state.DerivePhase(l, s)
	if phase == state.PhaseComplete {
		return "done"
	}
	return string(phase)
}

// spawnBackgroundRefresh fires `forge tickets refresh` as a detached child
// and returns immediately. Errors are intentionally swallowed — the worst
// case is the cache stays stale until the next TAB.
func spawnBackgroundRefresh() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	cmd := exec.Command(exe, "tickets", "refresh")
	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, nil, nil
	detach(cmd)
	_ = cmd.Start()
	// Don't Wait — let the orphan run to completion after the completion
	// process exits. Setpgid (handled in detach) keeps it alive.
}

// requireTicket validates the id and returns the layout for it. With
// scaffold=true, missing directories are created.
func requireTicket(id string, scaffold bool) (*config.Config, state.Layout, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, state.Layout{}, err
	}
	if err := ticket.Validate(id); err != nil {
		return nil, state.Layout{}, err
	}
	l := state.LayoutFor(cfg.TicketsRoot, id)
	if scaffold {
		if err := state.EnsureLayout(l); err != nil {
			return nil, state.Layout{}, err
		}
	}
	return cfg, l, nil
}

// ensureLinearFetched pulls LINEAR.md from the Linear CLI when the ticket
// is Linear-style and LINEAR.md is absent. No-op otherwise. Intended as a
// best-effort bootstrap — callers decide whether a missing LINEAR.md is
// fatal further downstream.
func ensureLinearFetched(cmd *cobra.Command, id string, l state.Layout) error {
	if !ticket.IsLinear(id) {
		return nil
	}
	if _, err := os.Stat(l.LinearMD); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return err
	}
	ui.L().Info("LINEAR.md absent; fetching")
	return newLinearFetch().RunE(cmd, []string{id})
}

// requireWorkDir errors out when the ticket dir doesn't exist on disk.
// Used by read-only commands that should not silently scaffold.
func requireWorkDir(id string) (*config.Config, state.Layout, error) {
	cfg, l, err := requireTicket(id, false)
	if err != nil {
		return nil, state.Layout{}, err
	}
	if _, err := os.Stat(l.Root); err != nil {
		return nil, state.Layout{}, fmt.Errorf("no work dir at %s; run: forge flux init %s", l.Root, id)
	}
	return cfg, l, nil
}

// buildRouter constructs the agent router from config: the configured
// default agent, plus any tool-capable backends needed for builder/critic
// phases when the default doesn't have tool calls.
func buildRouter(cfg *config.Config) *agent.Router {
	all := []agent.Backend{}

	if cfg.OpenAIAPIKey != "" {
		all = append(all, agent.NewPi(cfg.Model, cfg.OpenAIAPIKey, cfg.OpenAIBaseURL))
	}
	all = append(all, agent.NewClaude(cfg.ClaudeModel, cfg.PermissionMode))

	var def agent.Backend
	for _, b := range all {
		if b.Name() == cfg.Agent {
			def = b
			break
		}
	}
	if def == nil {
		// Configured agent has no entry — synthesize one so the router
		// returns a sensible error at preflight time rather than nil-deref.
		switch cfg.Agent {
		case "pi":
			def = agent.NewPi(cfg.Model, cfg.OpenAIAPIKey, cfg.OpenAIBaseURL)
		default:
			def = agent.NewClaude(cfg.ClaudeModel, cfg.PermissionMode)
		}
		all = append(all, def)
	}
	return agent.NewRouter(def, all)
}

// dispatchAgent runs Router.Dispatch with a pre-built request and event log.
// Returns the result or a sanitized error.
func dispatchAgent(ctx context.Context, cfg *config.Config, req agent.Request) (agent.Result, error) {
	r := buildRouter(cfg)
	picked, err := r.Pick(req.Phase)
	if err != nil {
		return agent.Result{}, err
	}
	model := cfg.Model
	if picked.Name() == "claude" {
		model = cfg.ClaudeModel
	}
	ui.L().Info("dispatch via %s (model=%s)", picked.Name(), model)
	res, err := r.Dispatch(ctx, req)
	if err != nil {
		return res, err
	}
	for _, w := range res.Wrote {
		ui.L().Info("wrote %s", w)
	}
	return res, nil
}
