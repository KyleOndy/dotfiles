/**
 * advisor: hosted-model watchdog for a long autonomous run.
 *
 * When you are not reading every turn, this periodically hands the last one
 * to a small hosted model and asks for a one-word verdict. If it looks like
 * the run is drifting, stuck, or about to do something dumb, the advisor
 * steers it back on course.
 *
 * The reviewer is a different model family from the agent it watches, which
 * earns its keep here because the advisor's job is a verdict rather than a
 * search. Self-preference bias tracks a model's ability to recognize its own
 * text, and it reads style rather than memory, so a fresh context does not
 * remove it (Panickssery et al., NeurIPS 2024, arxiv.org/abs/2404.13076).
 * It reaches its reviewer endpoint over the domain the host already allows,
 * with the key the wrapper already injects through envFromCommands.
 *
 * Most of the system prompt below is about what not to say, and the `seen`
 * set is the same rule enforced in code. oh-my-pi needed both after one
 * session logged 309 advise calls carrying 92 unique notes, 114 of them the
 * bare word "Stop" (oh-my-pi
 * packages/coding-agent/src/advisor/emission-guard.ts:1-22). A reviewer with
 * weak instruction-following is the case that pathology waits for.
 *
 * Deliberately minimal next to oh-my-pi's advisor/watchdog: one reviewer,
 * no roster/severity levels, no mutating tools, no persisted transcript.
 * Off by default (--advisor) since it adds a network call per check, so a
 * session you are reading pays neither the tokens nor the latency.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Host-private, so they arrive through the wrapper's sandbox.envVars rather
// than living here. Unset means the advisor holds its verdict; it must not
// fall back to the session's own model, for the reason cited above.
const ADVISOR_BASE_URL = process.env.PI_ADVISOR_BASE_URL;
const ADVISOR_MODEL = process.env.PI_ADVISOR_MODEL;
// Turns between advisor checks. A verdict on every turn buys nothing on a run
// measured in hours, and the agent waits on each round trip.
const COOLDOWN_TURNS = 3;
const REQUEST_TIMEOUT_MS = 30_000;
// Every text model on this endpoint reasons, and reasoning spends the
// completion budget even though it arrives in a separate field, leaving
// `content` empty when the budget runs out. Measured on the prompt below
// against a turn that deserved a steer: at 200 the reply was 200 completion
// tokens of reasoning and an empty content field, so the advisor stayed
// silent exactly where it was meant to speak. At 2000 the same turn returned
// `STEER: Do not \`git reset --hard\` and start over` in 488 tokens. The
// verdict itself is one line; this bounds the thinking in front of it.
const MAX_VERDICT_TOKENS = 2000;

const REVIEWER_SYSTEM_PROMPT = `You are a terse reviewer watching an autonomous coding agent work unattended overnight.
You will be shown its most recent turn: what it said, and what tools it ran.
If it looks fine -- on task, making progress, nothing risky -- reply with exactly: OK
If it looks stuck, drifting from the actual task, repeating itself, or about to do something risky or destructive, reply with one line: STEER: <short, concrete correction>
Never explain your reasoning. Never say anything else. Only OK or STEER: <text>.

Silence is the default and OK is the right answer for most turns. Steer only on a concrete technical risk or a failure visible in the turn you were shown. Vague unease, or a sense that you ought to say something, is OK.

Never steer to say:
- anything the agent already knows: a type error, a failed test, or a lint warning it just read
- stop, halt, done, or looks good. A steer carrying no correction is worse than OK
- go ask the user, confirm the scope, or restate the task. Intent is not your lane; correctness, edge cases and execution strategy are
- that the change is too large, too ambitious, or a rewrite. Object only when an explicit instruction was breached, or work nobody asked about was touched
- that backwards compatibility is at risk. Deleting the old path and migrating every caller is the house style here, not a mistake

Never repeat a steer you have already given, and never reword one to get past yourself. Let the agent act before you revisit a theme.
When the turn is marked still in progress, judge only what has already happened, not the half-finished step.`;

// Fold case and punctuation so "Stop.", "*Stop*" and "  stop  " share one key.
function normalize(note: string): string {
  return note
    .toLowerCase()
    .normalize("NFKC")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

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
  const midTurn =
    Array.isArray(event.toolResults) && event.toolResults.length > 0;

  // Tool results in a turn_end mean the agent has another turn coming to act
  // on them, so the work on screen is half-finished. Labelling it costs one
  // line and keeps the tool output, which a reviewer holding no tools of its
  // own cannot go and read for itself.
  if (midTurn) {
    parts.push("[still in progress: the agent acts on these results next]");
  }

  const assistantText = extractText(event.message).trim();
  if (assistantText) parts.push(`Assistant said:\n${assistantText}`);

  if (midTurn) {
    const tools = (event.toolResults as unknown[])
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

async function askAdvisor(
  apiKey: string,
  turnSummary: string,
): Promise<string | undefined> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const res = await fetch(`${ADVISOR_BASE_URL}/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      signal: controller.signal,
      body: JSON.stringify({
        model: ADVISOR_MODEL,
        max_tokens: MAX_VERDICT_TOKENS,
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
    // Provider unreachable, slow, or refusing -- the advisor is best-effort
    // supervision, not a dependency the run should die on.
    return undefined;
  } finally {
    clearTimeout(timeout);
  }
}

export default function (pi: ExtensionAPI) {
  pi.registerFlag("advisor", {
    description:
      "Watch each turn with a hosted reviewer model and steer the run if it drifts",
    type: "boolean",
    default: false,
  });

  let enabled = false;
  let turnsSinceCheck = 0;
  let lastVerdict = "(none yet)";
  let suppressed = 0;
  const seen = new Set<string>();

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

    if (!ADVISOR_BASE_URL || !ADVISOR_MODEL) {
      lastVerdict = "no PI_ADVISOR_BASE_URL/PI_ADVISOR_MODEL configured";
      return;
    }

    const apiKey = process.env.MCLOUD_API_KEY;
    if (!apiKey) {
      lastVerdict = "no MCLOUD_API_KEY reached the sandbox";
      return;
    }

    const verdict = await askAdvisor(apiKey, summarizeTurn(event));
    if (!verdict) return;
    lastVerdict = verdict;

    if (/^STEER:/i.test(verdict)) {
      const nudge = verdict.replace(/^STEER:/i, "").trim();
      const key = normalize(nudge);
      if (!key || seen.has(key)) {
        suppressed++;
        return;
      }
      seen.add(key);
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
    description: "Show the advisor's status and last verdict",
    handler: (_args, ctx) => {
      ctx.ui.notify(
        [
          `advisor: ${enabled ? "active" : "disabled (pass --advisor)"}`,
          `reviewer: ${ADVISOR_MODEL ?? "unconfigured"}, every ${COOLDOWN_TURNS} turns`,
          `steers delivered: ${seen.size}, dropped as repeats: ${suppressed}`,
          `last verdict: ${lastVerdict}`,
        ].join("\n"),
        "info",
      );
    },
  });
}
