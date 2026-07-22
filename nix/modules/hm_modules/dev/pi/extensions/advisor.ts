/**
 * advisor — local-model watchdog for unattended overnight pi runs.
 *
 * Companion to nix/pkgs/pi-overnight: when nobody's watching a long
 * autonomous run, this periodically hands the last turn to trex's local
 * model (a second batched client of the same mlx-openai-server process --
 * no extra model loaded, see nix/hosts/trex/home.nix) and asks a one-word
 * verdict. If it looks like the run is drifting, stuck, or about to do
 * something dumb, the advisor steers it back on course.
 *
 * Deliberately minimal next to oh-my-pi's advisor/watchdog: one reviewer,
 * no roster/severity levels, no mutating tools, no persisted transcript.
 * Off by default (--advisor) since it adds a network call per turn.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const LOCAL_MODEL_BASE_URL = "http://127.0.0.1:8000/v1";
const LOCAL_MODEL_ID = "qwen3-14b";
// Turns between advisor checks -- keeps it from competing with the main
// agent (and any task subagents) for the local server's concurrency slots
// on every single turn.
const COOLDOWN_TURNS = 3;
const REQUEST_TIMEOUT_MS = 30_000;

const REVIEWER_SYSTEM_PROMPT = `You are a terse reviewer watching an autonomous coding agent work unattended overnight.
You will be shown its most recent turn: what it said, and what tools it ran.
If it looks fine -- on task, making progress, nothing risky -- reply with exactly: OK
If it looks stuck, drifting from the actual task, repeating itself, or about to do something risky or destructive, reply with one line: STEER: <short, concrete correction>
Never explain your reasoning. Never say anything else. Only OK or STEER: <text>.`;

// Duck-typed: pi's own message/tool-result shapes aren't fully documented,
// so this extracts text defensively rather than assuming one exact shape.
function extractText(value: unknown): string {
  if (typeof value === "string") return value;
  if (value && typeof value === "object") {
    const v = value as Record<string, unknown>;
    if (Array.isArray(v.content)) {
      return (v.content as Array<Record<string, unknown>>)
        .filter((p) => typeof p?.text === "string")
        .map((p) => p.text as string)
        .join("\n");
    }
    if (typeof v.text === "string") return v.text;
    if (typeof v.output === "string") return v.output;
    if (typeof v.result === "string") return v.result;
  }
  try {
    return JSON.stringify(value).slice(0, 300);
  } catch {
    return String(value);
  }
}

function summarizeTurn(event: {
  message?: unknown;
  toolResults?: unknown;
}): string {
  const parts: string[] = [];
  const assistantText = extractText(event.message).trim();
  if (assistantText) parts.push(`Assistant said:\n${assistantText}`);

  if (Array.isArray(event.toolResults) && event.toolResults.length > 0) {
    const tools = event.toolResults
      .map((r) => {
        const rec = r as Record<string, unknown>;
        const name = (rec.toolName as string) ?? (rec.name as string) ?? "tool";
        const out = extractText(rec).slice(0, 300);
        return `- ${name}: ${out}`;
      })
      .join("\n");
    parts.push(`Tools run this turn:\n${tools}`);
  }

  return parts.join("\n\n") || "(no content this turn)";
}

async function askAdvisor(turnSummary: string): Promise<string | undefined> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const res = await fetch(`${LOCAL_MODEL_BASE_URL}/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      signal: controller.signal,
      body: JSON.stringify({
        model: LOCAL_MODEL_ID,
        max_tokens: 200,
        messages: [
          { role: "system", content: REVIEWER_SYSTEM_PROMPT },
          { role: "user", content: turnSummary },
        ],
      }),
    });
    if (!res.ok) return undefined;
    const data = (await res.json()) as {
      choices?: Array<{ message?: { content?: string } }>;
    };
    return data.choices?.[0]?.message?.content?.trim();
  } catch {
    // Local server unreachable, slow, or model not loaded -- the advisor is
    // best-effort supervision, not a dependency the run should die on.
    return undefined;
  } finally {
    clearTimeout(timeout);
  }
}

export default function (pi: ExtensionAPI) {
  pi.registerFlag("advisor", {
    description:
      "Watch each turn with the local model and steer the run if it drifts",
    type: "boolean",
    default: false,
  });

  let enabled = false;
  let turnsSinceCheck = 0;
  let lastVerdict = "(none yet)";

  pi.on("session_start", (_event, ctx) => {
    enabled = pi.getFlag("advisor") === true;
    if (enabled && ctx.hasUI) {
      ctx.ui.setStatus("advisor", ctx.ui.theme.fg("accent", "advisor"));
    }
  });

  pi.on("turn_end", async (event, ctx) => {
    if (!enabled) return;
    turnsSinceCheck++;
    if (turnsSinceCheck < COOLDOWN_TURNS) return;
    turnsSinceCheck = 0;

    const verdict = await askAdvisor(summarizeTurn(event));
    if (!verdict) return;
    lastVerdict = verdict;

    if (/^STEER:/i.test(verdict)) {
      const nudge = verdict.replace(/^STEER:/i, "").trim();
      if (ctx.hasUI) ctx.ui.notify(`advisor: ${nudge}`, "warning");
      pi.sendMessage(
        {
          customType: "advisor-steer",
          content: `[advisor] ${nudge}`,
          display: true,
        },
        { deliverAs: "steer" },
      );
    }
  });

  pi.registerCommand("advisor", {
    description: "Show the local-model advisor's status and last verdict",
    handler: (_args, ctx) => {
      ctx.ui.notify(
        [
          `advisor: ${enabled ? "active" : "disabled (pass --advisor)"}`,
          `checks every ${COOLDOWN_TURNS} turns`,
          `last verdict: ${lastVerdict}`,
        ].join("\n"),
        "info",
      );
    },
  });
}
