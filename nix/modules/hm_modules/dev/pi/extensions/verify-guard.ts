/**
 * verify-guard: deterministic nag that the project's verifier has been run.
 *
 * The rung this closes is Assert/Verify in ~/.pi/agent/AGENTS.md. Skills
 * asking a model to check its work are pull-mode: the model has to elect to
 * load them and then elect to obey, which is exactly the assumption that
 * fails on the cheap models this harness is built to run. This is push-mode
 * and carries no model judgment at all, so it behaves the same on a 4B model
 * as on a frontier one.
 *
 * Why bother, given the agent can already run `make check` itself: a model
 * grading its own work is a weak filter no matter whose model it is. The best
 * measured review condition catches under a third of injected errors
 * (arxiv.org/abs/2603.12123), while grounded compiler and runtime feedback
 * moves correctness twenty to thirty points. The verifier is the strong
 * signal; this makes sure it is not skipped.
 *
 * Config (merged: global <- project), the project file winning:
 *   ~/.pi/agent/verify.json   and   <cwd>/.pi/verify.json
 *   { "enabled": true, "command": "make check" }
 * With no command configured the guard is inert rather than inventing one, so
 * a repo that has no verifier is not nagged about a command that cannot run.
 *
 * Scope and limits (deliberately honest):
 *   - A run that exits non-zero does not clear the counter, and does not
 *     re-arm the nag either: the agent has already reported, so repeating the
 *     steer only burns turns. The footer holds `failed` until something goes
 *     green, which is the state a human needs to see.
 *   - It does not distinguish a verifier that failed from one that could not
 *     run here (the sandbox denies the nix daemon socket without
 *     --allow-nix). Both mean look at it yourself, so one state covers them.
 *   - Matching is a normalized substring of the bash command, so a configured
 *     `make check` does not recognize `nix flake check --impure` as the same
 *     thing, and `echo make check` satisfies it (it exits zero too). This
 *     nags; it does not gate.
 *   - Edits are counted from the edit/write tools plus a short list of obvious
 *     bash mutations. An obfuscated write (python, a heredoc into a variable
 *     path) leaves the counter untouched.
 */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type {
  ExtensionAPI,
  ToolCallEvent,
} from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";

interface VerifyGuardConfig {
  enabled: boolean;
  command: string | null;
}

const DEFAULT_CONFIG: VerifyGuardConfig = { enabled: true, command: null };

// Bash forms that write without going through the edit/write tools. Not a
// parser: each is a shape common enough that missing it would make the edit
// counter read zero through a whole session of heredoc writes.
const BASH_MUTATORS = [
  // Redirection into a path, heredocs included. The lookbehind drops fd-dups
  // (`2>&1`) and the lookahead drops the null sink, because a diagnostic
  // command silencing its own stderr writes nothing: counting those made the
  // counter climb through a session that only ever read.
  /(?<![0-9&])>>?\s*(?!&|\/dev\/(?:null|stdout|stderr))\S/,
  /\bsed\s+(-\S*\s+)*-\S*i/, // sed -i, in any flag order
  /\btee\b/,
  /\b(mv|rm|cp|install|truncate)\b/,
  /\bgit\s+(apply|checkout|restore|rm|mv)\b/,
  /\bpatch\b/,
];

function agentDir(): string {
  return process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent");
}

// Fold case and whitespace so `make  check` and `MAKE CHECK` share one key.
function normalize(command: string): string {
  return command.toLowerCase().replace(/\s+/g, " ").trim();
}

function loadConfig(cwd: string): VerifyGuardConfig {
  const merge = (base: VerifyGuardConfig, path: string): VerifyGuardConfig => {
    if (!existsSync(path)) return base;
    try {
      const o = JSON.parse(
        readFileSync(path, "utf-8"),
      ) as Partial<VerifyGuardConfig>;
      return {
        enabled: o.enabled ?? base.enabled,
        command: o.command ?? base.command,
      };
    } catch (e) {
      console.error(`verify-guard: could not parse ${path}: ${e}`);
      return base;
    }
  };
  let cfg = DEFAULT_CONFIG;
  cfg = merge(cfg, join(agentDir(), "verify.json"));
  cfg = merge(cfg, join(cwd, ".pi", "verify.json"));
  return cfg;
}

function isMutation(event: ToolCallEvent): boolean {
  if (event.toolName === "edit" || event.toolName === "write") return true;
  if (event.toolName !== "bash") return false;
  const command = (event.input as Record<string, unknown>).command;
  if (typeof command !== "string") return false;
  return BASH_MUTATORS.some((re) => re.test(command));
}

// Structural rather than the exported result-event type: this reads only the
// tool name, the input command, and the result text.
interface ToolOutcome {
  toolName: string;
  input: unknown;
  content?: unknown;
  isError?: boolean;
}

function isVerifyRun(
  event: { toolName: string; input: unknown },
  command: string,
): boolean {
  if (event.toolName !== "bash") return false;
  const c = (event.input as Record<string, unknown>).command;
  return typeof c === "string" && normalize(c).includes(normalize(command));
}

// Pi's bash tool carries the exit code in the result text, not in its
// details: pi's own renderer scrapes /exit code: (\d+)/ and treats the
// line's absence as success (examples/extensions/built-in-tool-renderer.ts,
// renderResult). Reading it the same way keeps this in step with what the
// TUI shows the human sitting in front of it.
function failed(event: ToolOutcome): boolean {
  if (event.isError === true) return true;
  const parts = Array.isArray(event.content) ? event.content : [];
  const text = parts
    .map((c) => c as { type?: string; text?: string })
    .filter((c) => c.type === "text")
    .map((c) => c.text ?? "")
    .join("\n");
  const m = text.match(/exit code: (\d+)/);
  return m !== null && m[1] !== "0";
}

export default function (pi: ExtensionAPI) {
  pi.registerFlag("no-verify-guard", {
    description: "Do not track whether the project's verifier has been run",
    type: "boolean",
    default: false,
  });

  let cfg = DEFAULT_CONFIG;
  let active = false;
  let editsSinceVerify = 0;
  let verifiedThisTurn = false;
  let failedThisTurn = false;
  let verifyFailing = false;
  let verifyRuns = 0;
  let steeredThisEpisode = false;

  const state = (): string => {
    if (!active) return "off";
    if (verifyFailing) {
      return editsSinceVerify > 0
        ? `failed (${editsSinceVerify} edits)`
        : "failed";
    }
    if (verifyRuns === 0 && editsSinceVerify === 0) return "not run";
    if (editsSinceVerify > 0) return `stale (${editsSinceVerify} edits)`;
    return "current";
  };

  // Stale and failed are the states worth interrupting for, so each takes a
  // row of its own under the editor and names the command; the footer entry
  // stands down while it is up. The quiet states stay in the footer, where a
  // line shared with every other extension is the right price for them.
  // Nothing is shown in both places.
  const showStatus = (ctx: { hasUI: boolean; ui?: unknown }): void => {
    if (!ctx.hasUI || !active) return;
    const ui = ctx.ui as {
      setStatus: (k: string, v?: string) => void;
      setWidget: (
        k: string,
        content?: (
          tui: unknown,
          theme: { fg: (c: string, s: string) => string },
        ) => { render: (width: number) => string[]; invalidate: () => void },
        options?: { placement: "aboveEditor" | "belowEditor" },
      ) => void;
      theme: { fg: (c: string, s: string) => string };
    };

    if (editsSinceVerify === 0 && !verifyFailing) {
      ui.setWidget("verify-guard", undefined);
      ui.setStatus("verify-guard", `verify: ${state()}`);
      return;
    }

    ui.setStatus("verify-guard", undefined);
    // render() reads the live counter rather than a value captured when the
    // widget was built, so a mid-turn edit does not leave a stale count on
    // screen. Width is only knowable here, and the configured command runs
    // long enough to wrap onto a second row without the truncation.
    ui.setWidget(
      "verify-guard",
      (_tui, theme) => ({
        invalidate: () => {},
        render: (width: number) => [
          truncateToWidth(
            (verifyFailing
              ? theme.fg("error", "verify: last run failed")
              : theme.fg(
                  "warning",
                  `verify: ${editsSinceVerify} edit(s) unverified`,
                )) + theme.fg("dim", `  ${cfg.command}`),
            width,
            theme.fg("dim", "..."),
          ),
        ],
      }),
      { placement: "belowEditor" },
    );
  };

  pi.on("session_start", (_event, ctx) => {
    if (pi.getFlag("no-verify-guard") === true) return;
    cfg = loadConfig(ctx.cwd);
    active = cfg.enabled && cfg.command !== null;
    showStatus(ctx);
  });

  // The verifier's own invocation must not count as an edit, which is why
  // this returns before isMutation. Whether it passed is not knowable here,
  // so the outcome is read in tool_result.
  pi.on("tool_call", (event) => {
    if (!active || cfg.command === null) return;
    if (isVerifyRun(event, cfg.command)) return;
    if (isMutation(event)) editsSinceVerify++;
  });

  pi.on("tool_result", (event) => {
    if (!active || cfg.command === null) return;
    const outcome = event as unknown as ToolOutcome;
    if (!isVerifyRun(outcome, cfg.command)) return;
    if (failed(outcome)) failedThisTurn = true;
    else verifiedThisTurn = true;
  });

  pi.on("turn_end", (event, ctx) => {
    if (!active || cfg.command === null) return;

    if (verifiedThisTurn) {
      verifiedThisTurn = false;
      failedThisTurn = false;
      verifyRuns++;
      editsSinceVerify = 0;
      verifyFailing = false;
      steeredThisEpisode = false;
      showStatus(ctx);
      return;
    }

    // A failing run leaves the counter alone: nothing was verified. It also
    // withholds the steer, because the agent has just run the command and
    // reported its output, and asking again produces the same report. The
    // widget carries `failed` until a run comes back green, which is the
    // state a human needs to see. This is the loop that used to burn turns
    // when the verifier could not run in the sandbox at all.
    if (failedThisTurn) {
      failedThisTurn = false;
      verifyRuns++;
      verifyFailing = true;
      steeredThisEpisode = true;
    }
    showStatus(ctx);

    // Tool results in a turn_end mean the agent has another turn coming to act
    // on them, so it is still working and a nag would land mid-stride. A turn
    // carrying none is the agent talking, which is the closest observable
    // signal to it being finished.
    const stillWorking =
      Array.isArray(event.toolResults) && event.toolResults.length > 0;
    if (stillWorking || editsSinceVerify === 0 || steeredThisEpisode) return;

    steeredThisEpisode = true;
    pi.sendMessage(
      {
        customType: "verify-guard-steer",
        content:
          `[verify-guard] ${editsSinceVerify} edit(s) stand unverified. Run \`${cfg.command}\` ` +
          `and report its real output before calling this done. If it cannot run here, say so and say why.`,
        display: true,
      },
      { deliverAs: "steer" },
    );
  });

  pi.registerCommand("verify", {
    description: "Show whether the project's verifier has been run",
    handler: (_args, ctx) => {
      ctx.ui.notify(
        [
          `verify-guard: ${active ? "active" : "inert (no command configured)"}`,
          `command: ${cfg.command ?? "(none)"}`,
          `state: ${state()}`,
          `runs this session: ${verifyRuns}`,
        ].join("\n"),
        "info",
      );
    },
  });
}
