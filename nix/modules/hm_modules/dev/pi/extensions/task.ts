/**
 * task: parallel read-only subagents for the pi coding agent.
 *
 * pi has no built-in subagent tool, but its SDK/extension API is meant for
 * exactly this: a custom tool whose execute() spawns nested pi runs. This
 * registers `task`: the model can hand off several independent, read-heavy
 * jobs (explore a directory, summarize a file, answer a question about the
 * codebase) to parallel one-shot subagents, and gets back a combined summary
 * instead of burning its own context on the exploration.
 *
 * Subagent mechanics:
 *   - Each task runs as `$PI_REAL_BIN --tools ... --model ... --mode json
 *     --no-session <task>`. PI_REAL_BIN is exported by
 *     nix/pkgs/pi-wrapper/wrapper.sh -- it points at the real, unwrapped pi
 *     binary. Spawning that directly (instead of re-invoking the `pi` sandbox
 *     wrapper) means a subagent does NOT open a second, redundant
 *     srt/bwrap/sandbox-exec layer: OS-level sandboxes confine the whole
 *     process tree, so a plain child of the already-sandboxed pi process
 *     inherits the same confinement for free.
 *   - Subagents are read-only: no edit/write/bash. We deliberately skipped
 *     oh-my-pi's worktree isolation (real complexity for a personal tool) --
 *     read-only access sidesteps the failure mode isolation exists to solve
 *     (parallel subagents racing to edit the same files) without needing it.
 *   - An agent named in `agents/*.md` carries its own tool allowlist and
 *     role prompt, and runs on its own seat, so a scout can run on something
 *     cheap while the parent stays on the expensive model that needs the
 *     context. Unnamed tasks, and an agent whose seat is unset and not
 *     required, inherit the parent's model, which is the only safe default:
 *     a cloud parent fanning out to a small local model gets research too
 *     weak to act on, and a local parent fanning out to a cloud model spends
 *     real money N-at-a-time from a session whose whole point was that it
 *     cost nothing.
 *   - The child's NDJSON is read line by line while it runs, so the tool row
 *     and the rows pinned above the editor report what each subagent is doing
 *     while it runs, not only what it concluded at the end. Every 10s the
 *     PI_CLASSIFY_MODEL seat turns the prose and tool calls since the last
 *     status into a phrase; without that seat the row samples the tool in
 *     flight or the tail of the prose. Bulk
 *     events are not logged; the rest go to its own file under
 *     ~/.pi/agent/task-logs. Those are the only durable record a subagent
 *     leaves: they run --no-session, so their stdout is otherwise discarded
 *     once the final message has been scraped out of it. The sandbox denies
 *     reading that directory, so the record is for the human, not for a later
 *     agent to mine.
 *   - No isolation/schema/typed-output beyond a plain text summary per
 *     task. If that ever stops being enough, revisit -- it hasn't been
 *     needed yet.
 */

import { spawn } from "node:child_process";
import { appendFileSync, existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { Type } from "typebox";
import type { Api, Model } from "@earendil-works/pi-ai";
import {
  type ExtensionAPI,
  type ExtensionContext,
  type ModelRegistry,
  type Theme,
  getAgentDir,
  parseFrontmatter,
} from "@earendil-works/pi-coding-agent";
import { Text, truncateToWidth } from "@earendil-works/pi-tui";

// Matches the local model server's --prompt-concurrency 3 (mlx-openai-server
// launchd config, nix/hosts/trex/home.nix) -- no point queuing more subagents
// than it will actually run in parallel. Applied to cloud fan-out too: 3
// independent read-only explorations is already a wide net.
const MAX_CONCURRENCY = 3;
const SUBAGENT_TOOLS = "read,grep,find,ls";
// A read-only research task that has not finished inside this is wedged, not
// slow. The child is killed rather than rejected, so whatever it had already
// said still comes back.
const TASK_TIMEOUT_MS = 10 * 60_000;
// SIGTERM first so the child can flush, SIGKILL if it will not go.
const KILL_GRACE_MS = 5_000;
// The trail is a tail, not a transcript: a subagent that runs a hundred greps
// must not grow the tool row without bound. The full sequence is in the log.
const MAX_TRAIL = 12;
// How much of the prose a subagent is streaming right now to keep per task.
// Json-mode message_update events are delta-only, so the tail is assembled
// from deltas; capped so a long monologue costs a bounded string.
const LIVE_TAIL = 240;
// The rows redraw on every spinner frame and prose arrives per token, so a
// row that tracked it live would be unreadable.
const STATUS_MS = 10_000;
// Under STATUS_MS, so a task never has two status calls in flight.
const STATUS_TIMEOUT_MS = 8_000;
// Characters, from the end.
const STATUS_WINDOW = 2_000;
// A seat that reasons spends this too, and an empty reply falls back to the
// raw sample.
const STATUS_TOKENS = 100;
const STATUS_PROMPT =
  "You write the status line for a coding subagent. Reply with one present-tense phrase of at most 8 words saying what it is doing right now. No preamble, no quotes, no trailing period.";
// Unset or empty: the host has no trust list, so nothing is checked.
const TRUSTED_PROVIDERS = (process.env.PI_TRUSTED_PROVIDERS ?? "")
  .split(",")
  .filter(Boolean);

interface Agent {
  name: string;
  description: string;
  tools: string;
  // Frontmatter `model:`, which the agent's seat overrides.
  model?: string;
  // Frontmatter `seat: required`: with its seat unset, the agent refuses
  // rather than run the session's model.
  seatRequired: boolean;
  // Frontmatter `needs: image`: the agent refuses a model whose catalog entry
  // takes no image input, which would drop every image it is handed.
  needsImage: boolean;
  systemPrompt: string;
}

// An agent's name becomes part of its seat's variable name, and a name that
// is not a shell identifier aborts the wrapper's `export`.
const AGENT_NAME = /^[A-Za-z0-9_]+$/;

interface TaskResult {
  index: number;
  task: string;
  state: "running" | "done" | "failed";
  summary: string;
  // The tool call in flight right now, absent while the subagent is thinking.
  activity?: string;
  // Tail of the thinking or text block the subagent is streaming: the only
  // narration there is between tool calls, and what a raw sample shows in
  // place of a bare "thinking". Empty while a tool runs, before the first
  // block starts, and once the task settles.
  live: string;
  // What a running row shows, replaced every STATUS_MS: the PI_CLASSIFY_MODEL
  // seat's summary of the window, or without a usable seat a raw sample.
  // Absent before the first.
  status?: string;
  // Prose and tool calls since the last status was taken.
  window: string;
  trail: string[];
  tools: number;
  startedAt: number;
  elapsedMs: number;
  tokens: number;
  cost: number;
}

interface ChildOutcome {
  events: Record<string, unknown>[];
  stderr: string;
  code: number;
  aborted: boolean;
  timedOut: boolean;
}

// A subagent holding `task` can fan out again. Upstream's own example leaves
// the allowlist optional and its worker.md declares none, which inherits the
// full tool surface including this tool (pi 0.84.3
// examples/extensions/subagent/agents/worker.md). Unconditional here, and
// `task` is never in it, so the recursion has nowhere to start.
function parseTools(value: unknown): string {
  const raw =
    typeof value === "string"
      ? value.split(",")
      : Array.isArray(value)
        ? value
        : [];
  const tools = raw
    .filter((t): t is string => typeof t === "string")
    .map((t) => t.trim())
    .filter((t) => t && t !== "task");
  return tools.length > 0 ? tools.join(",") : SUBAGENT_TOOLS;
}

// ~/.pi/agent/agents/*.md: frontmatter name/description/tools/model/seat/
// needs with the body as the role prompt. Read once at registration, like
// every other file under the extensions symlink, so an edit lands on
// /reload. Upstream also walks up for a project-scoped <repo>/.pi/agents;
// nothing has wanted a repo-specific researcher yet.
function discoverAgents(): Agent[] {
  const dir = join(getAgentDir(), "agents");
  if (!existsSync(dir)) return [];

  const agents: Agent[] = [];
  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    return agents;
  }

  for (const entry of entries) {
    if (!entry.endsWith(".md")) continue;
    let content: string;
    try {
      content = readFileSync(join(dir, entry), "utf-8");
    } catch {
      continue;
    }
    // One malformed file must not take out every other agent beside it.
    const { frontmatter, body } = parseFrontmatter<{
      name?: unknown;
      description?: unknown;
      tools?: unknown;
      model?: unknown;
      seat?: unknown;
      needs?: unknown;
    }>(content);
    if (
      typeof frontmatter.name !== "string" ||
      typeof frontmatter.description !== "string"
    )
      continue;

    agents.push({
      name: frontmatter.name,
      description: frontmatter.description,
      tools: parseTools(frontmatter.tools),
      model:
        typeof frontmatter.model === "string" ? frontmatter.model : undefined,
      seatRequired: frontmatter.seat === "required",
      needsImage: frontmatter.needs === "image",
      systemPrompt: body.trim(),
    });
  }
  return agents;
}

async function runWithConcurrency<T, R>(
  items: T[],
  limit: number,
  fn: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  async function worker(): Promise<void> {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i], i);
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, worker),
  );
  return results;
}

// One file per subagent, in a directory the wrapper names in the sandbox's
// denyRead (nix/pkgs/pi-wrapper/wrapper.sh). Writing there works; reading,
// listing, stat and rename do not, so the agent records its own fan-out and
// can never read one back, its own included. That rules out size-based
// rotation, hence a file per run: the wrapper makes the directory and prunes
// it, being the only part of this that runs outside the sandbox.
function logFileFor(batch: string, index: number, stamp: string): string {
  const dir = process.env.PI_TASK_LOG_DIR ?? join(getAgentDir(), "task-logs");
  const safeBatch = batch.replace(/[^A-Za-z0-9_-]/g, "-");
  return join(dir, `${stamp}_${safeBatch}_${index}.jsonl`);
}

// A log that cannot be written must never take the tool down with it. With the
// directory missing (pi started outside the wrapper) that is every call, which
// is the intended outcome rather than a failure to report.
function logEvent(file: string, entry: Record<string, unknown>): void {
  try {
    appendFileSync(
      file,
      `${JSON.stringify({ ts: new Date().toISOString(), ...entry })}\n`,
    );
  } catch {
    // logging must never break a fan-out
  }
}

// `provider/id` is the form `pi --model` accepts alongside a bare id or a
// pattern (docs/usage.md), and the only one that survives an id registered
// under more than one provider. Undefined before a model is resolved.
function subagentModel(ctx: ExtensionContext): string | undefined {
  return ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined;
}

// An agent runs on its seat, PI_AGENT_MODEL_<NAME>, else its frontmatter
// `model:`, else the session's model. The agents directory is one symlink
// shared by every host, so a host picks an agent's model through its seats,
// which the wrapper exports. Every refusal throws, so the model sees a tool
// error, and names a variable or a provider, never a model id: it lands in
// the transcript.
function resolveModel(
  agent: Agent | undefined,
  ctx: ExtensionContext,
): string | undefined {
  let model = subagentModel(ctx);
  let who = "the session model";
  if (agent) {
    if (!AGENT_NAME.test(agent.name))
      throw new Error(
        `task: agent name "${agent.name}" must match ${AGENT_NAME.source}, since it names the agent's seat variable.`,
      );
    const seat = `PI_AGENT_MODEL_${agent.name.toUpperCase()}`;
    const seatModel = process.env[seat] || undefined;
    if (!seatModel && agent.seatRequired)
      throw new Error(
        `task: agent ${agent.name} requires its seat, and ${seat} is unset. Add a ${seat}=provider/id[:level] line to this host's pi_seats (sops) and redeploy, or set ${seat} in the environment pi starts from.`,
      );
    model = seatModel ?? agent.model ?? model;
    who = `agent ${agent.name} (seat ${seat})`;
  }

  const slash = model ? model.indexOf("/") : -1;
  const provider = model && slash > 0 ? model.slice(0, slash) : undefined;

  if (model && TRUSTED_PROVIDERS.length > 0) {
    if (!provider)
      throw new Error(
        `task: ${who} names no provider, so it cannot be checked against PI_TRUSTED_PROVIDERS. Write the seat as provider/id.`,
      );
    if (!TRUSTED_PROVIDERS.includes(provider))
      throw new Error(
        `task: ${who} is on provider ${provider}, which is not in PI_TRUSTED_PROVIDERS (${TRUSTED_PROVIDERS.join(", ")}). Point it at a model on one of those.`,
      );
  }

  // An id the catalog lacks runs as a copy of its provider's default model,
  // so there is no entry to hold it to; that is how a new model gets tried.
  if (agent?.needsImage && model && provider) {
    const entry = ctx.modelRegistry.find(
      provider,
      stripLevel(model.slice(slash + 1)),
    );
    if (entry && !entry.input.includes("image"))
      throw new Error(
        `task: ${who} is on a model whose catalog entry takes no image input, so every image would be dropped. Point the seat at a model whose pi_models_json entry has "image" in input and passes mcloud-pins' image check.`,
      );
  }
  return model;
}

const LEVELS = new Set([
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
]);

// pi's split: a suffix after the last `:` is a level only when it names one.
function stripLevel(id: string): string {
  const colon = id.lastIndexOf(":");
  return colon >= 0 && LEVELS.has(id.slice(colon + 1))
    ? id.slice(0, colon)
    : id;
}

type Reasoning = NonNullable<
  Parameters<ModelRegistry["streamSimple"]>[2]
>["reasoning"];

interface StatusSeat {
  model: Model<Api>;
  reasoning: Reasoning;
}

// Undefined, so rows are sampled raw, when PI_CLASSIFY_MODEL is unset, on a
// provider outside PI_TRUSTED_PROVIDERS, or an id the catalog lacks.
function statusSeat(registry: ModelRegistry): StatusSeat | undefined {
  const value = process.env.PI_CLASSIFY_MODEL ?? "";
  const slash = value.indexOf("/");
  if (slash <= 0) return undefined;
  const provider = value.slice(0, slash);
  if (TRUSTED_PROVIDERS.length > 0 && !TRUSTED_PROVIDERS.includes(provider))
    return undefined;
  const id = value.slice(slash + 1);
  const bare = stripLevel(id);
  const model = registry.find(provider, bare);
  if (!model) return undefined;
  // No level, or off, asks for no reasoning rather than the session default.
  const level = id.slice(bare.length + 1);
  return {
    model,
    reasoning: (level && level !== "off" ? level : undefined) as Reasoning,
  };
}

// A failed request comes back as an empty reply, not a throw, so undefined
// covers both.
async function summarize(
  registry: ModelRegistry,
  seat: StatusSeat,
  task: string,
  window: string,
  signal: AbortSignal,
): Promise<string | undefined> {
  const reply = await registry
    .streamSimple(
      seat.model,
      {
        systemPrompt: STATUS_PROMPT,
        messages: [
          {
            role: "user",
            content: `Task: ${oneLine(task, 300)}\n\nSince the last status:\n${window}`,
            timestamp: Date.now(),
          },
        ],
      },
      { maxTokens: STATUS_TOKENS, reasoning: seat.reasoning, signal },
    )
    .result();
  const text = reply.content
    .flatMap((part) => (part.type === "text" ? [part.text] : []))
    .join("");
  // Drawn straight into the terminal, where a control character is a command.
  return oneLine(text.replace(/[\p{Cc}\p{Cf}]/gu, " "), 60) || undefined;
}

interface AssistantResult {
  role?: string;
  stopReason?: string;
  errorMessage?: string;
  content?: { type?: string; text?: string }[];
}

// Keep in sync with pi-session/results.py through the shared result fixtures.
export function classifyResult(
  events: Record<string, unknown>[],
  exitCode = 0,
  aborted = false,
  timedOut = false,
): { state: string; text: string; error: string | null } {
  let final: AssistantResult | undefined;
  let settled = false;
  for (const event of events) {
    if (!event || typeof event !== "object") continue;
    if (event.type === "agent_start") {
      final = undefined;
      settled = false;
    } else if (event.type === "message_end") {
      const message = event.message as AssistantResult | undefined;
      if (message?.role === "assistant") {
        final = message;
        settled = false;
      }
    } else if (event.type === "agent_end" && !final) {
      for (const message of (event.messages ?? []) as AssistantResult[]) {
        if (message.role === "assistant") final = message;
      }
    } else if (event.type === "agent_settled") {
      settled = true;
    }
  }
  const text = (Array.isArray(final?.content) ? final.content : [])
    .filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text)
    .join("\n")
    .trim()
    .slice(0, 1048576);
  const reason = final?.stopReason;
  let state = "success";
  let error: string | null = null;
  if (timedOut) {
    state = "timeout";
    error = "Agent timed out";
  } else if (aborted || reason === "aborted") {
    state = "aborted";
    error = "Agent was cancelled";
  } else if (exitCode !== 0) {
    state = "error";
    error = `Agent process exited with code ${exitCode}`;
  } else if (reason === "error") {
    state = "error";
    error = final?.errorMessage || "Provider request failed";
  } else if (!settled || reason !== "stop") {
    state = "incomplete";
    error = "Agent did not settle with a completed assistant reply";
  } else if (!text) {
    state = "empty";
    error = "Agent returned an empty assistant reply";
  }
  return { state, text, error };
}

// Tasks are model-authored paragraphs. A collapsed row is a label for one,
// not the text of it, so it gets a single line's worth and no newlines.
function oneLine(text: string, limit = 80): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > limit ? `${flat.slice(0, limit - 3)}...` : flat;
}

// The freshest words of a stream sit at its end, so a live tail shows its
// last line's worth, not its first -- unlike oneLine, which labels from the
// front. Callers prefix "\u2026" to mark a join mid-sentence.
function liveTail(text: string, limit = 56): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > limit ? flat.slice(flat.length - limit) : flat;
}

// Between tool calls, the prose the subagent is streaming, `…` marking a
// join mid-sentence.
function rawStatus(r: TaskResult): string {
  return r.activity ?? (r.live ? `…${liveTail(r.live)}` : "thinking");
}

function addToWindow(r: TaskResult, text: string): void {
  r.window = (r.window + text).slice(-STATUS_WINDOW);
}

// Tool argument objects have no shape in common, so name the target from the
// arguments the built-in read-only tools actually use, and fall back to the
// first string in the object for anything else.
const TARGET_ARGS = ["path", "pattern", "query", "command", "file", "glob"];

function activityOf(toolName: string, args: unknown): string {
  const record = (args ?? {}) as Record<string, unknown>;
  const named = TARGET_ARGS.map((key) => record[key]).find(
    (value) => typeof value === "string" && value.trim(),
  );
  const target =
    named ??
    Object.values(record).find(
      (value) => typeof value === "string" && value.trim(),
    );
  return typeof target === "string"
    ? `${toolName} ${oneLine(target, 48)}`
    : toolName;
}

function fmtTokens(n: number): string {
  return n >= 1000 ? `${Math.round(n / 1000)}k tok` : `${n} tok`;
}

function fmtElapsed(ms: number): string {
  const s = Math.round(ms / 1000);
  return s < 60
    ? `${s}s`
    : `${Math.floor(s / 60)}m${String(s % 60).padStart(2, "0")}s`;
}

// One subagent's line, in the tool row and the pinned widget alike.
// `run`/`done`/`FAILED` are words rather than glyphs so the state survives
// without color, and the latter two match the wire format the model already
// receives. A running subagent's clock is read at render time, not at its
// last event, so one thinking for minutes does not look stalled.
function taskRow(r: TaskResult, theme: Theme): string {
  const label =
    r.state === "running"
      ? theme.fg("warning", "run   ")
      : r.state === "done"
        ? theme.fg("success", "done  ")
        : theme.fg("error", "FAILED");
  const subject =
    r.state === "running"
      ? theme.fg("muted", r.status ?? "starting")
      : theme.fg("muted", oneLine(r.task));
  const trailing =
    r.state === "running"
      ? theme.fg(
          "dim",
          `  ${r.tools} tool${r.tools === 1 ? "" : "s"}  ${fmtElapsed(Date.now() - r.startedAt)}`,
        )
      : r.elapsedMs
        ? theme.fg("dim", `  ${fmtElapsed(r.elapsedMs)}`)
        : "";
  return `${theme.fg("dim", `[${r.index + 1}]`)} ${label} ${subject}${trailing}`;
}

// pi.exec would be the shorter call, but it buffers: it resolves once, after
// the child has exited, which is exactly the ten minutes of silence this tool
// used to report nothing during. spawn hands back the NDJSON as it is written.
function runChild(
  bin: string,
  args: string[],
  signal: AbortSignal | undefined,
  onEvent: (event: Record<string, unknown>) => void,
): Promise<ChildOutcome> {
  return new Promise((resolve) => {
    const proc = spawn(bin, args, { stdio: ["ignore", "pipe", "pipe"] });
    let events: Record<string, unknown>[] = [];
    let stderr = "";
    let buffer = "";
    let aborted = false;
    let timedOut = false;
    let oversized = false;
    let killTimer: ReturnType<typeof setTimeout> | undefined;
    let settled = false;

    const kill = (): void => {
      proc.kill("SIGTERM");
      killTimer = setTimeout(() => proc.kill("SIGKILL"), KILL_GRACE_MS);
    };

    // spawn's own `signal` and `timeout` options are node additions whose
    // support under pi's bundled bun is unverified, and the two cases report
    // differently below, so both are handled here.
    const timer = setTimeout(() => {
      timedOut = true;
      kill();
    }, TASK_TIMEOUT_MS);
    const onAbort = (): void => {
      aborted = true;
      kill();
    };
    if (signal?.aborted) onAbort();
    else signal?.addEventListener("abort", onAbort, { once: true });

    const readLine = (text: string): void => {
      if (!text.trim()) return;
      let event: unknown;
      try {
        event = JSON.parse(text);
      } catch {
        return;
      }
      if (event && typeof event === "object") {
        const record = event as Record<string, unknown>;
        if (record.type === "agent_start") events = [record];
        if (
          record.type === "message_end" &&
          (record.message as AssistantResult | undefined)?.role === "assistant"
        )
          events = [record];
        if (record.type === "agent_settled") events.push(record);
        onEvent(record);
      }
    };

    proc.stdout.on("data", (chunk) => {
      const text = String(chunk);
      buffer += text;
      if (buffer.length > 16 * 1024 * 1024) {
        oversized = true;
        stderr = "Child event exceeded 16 MiB";
        buffer = "";
        kill();
        return;
      }
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) readLine(line);
    });
    proc.stderr.on("data", (chunk) => {
      stderr = (stderr + String(chunk)).slice(-4096);
    });

    const finish = (code: number): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      signal?.removeEventListener("abort", onAbort);
      if (buffer.trim()) readLine(buffer);
      resolve({
        events,
        stderr,
        code: oversized ? 1 : code,
        aborted,
        timedOut,
      });
    };
    // A child killed by a signal reports a null code; reading that as 0 would
    // let an OOM kill pass for a clean run.
    proc.on("close", (code, signalName) =>
      finish(code ?? (signalName ? 1 : 0)),
    );
    proc.on("error", (err) => {
      stderr += `${err.message}\n`;
      finish(1);
    });
  });
}

export default function (pi: ExtensionAPI) {
  const agents = discoverAgents();
  const roster = agents.map((a) => `${a.name}: ${a.description}`).join("; ");

  pi.registerTool({
    name: "task",
    label: "Task",
    description: agents.length
      ? `Delegate independent, read-only exploration tasks to parallel subagents. Named agents: ${roster}.`
      : "Delegate independent, read-only exploration tasks to parallel subagents running on your own model.",
    promptSnippet:
      "Fan out independent, read-heavy work (explore dirs, summarize files, answer questions about the codebase) to parallel subagents",
    promptGuidelines: [
      "Use for independent work you can fully describe up front -- exploring several directories, summarizing multiple files, running the same kind of investigation across different inputs.",
      "Each task runs as its own one-shot pi session with no access to this conversation; put everything it needs in `context` (shared across all tasks) or the task text itself.",
      "Subagents are read-only (read/grep/find/ls) -- they cannot edit files or run bash. Use them for research, not for making changes.",
      "Name an `agent` to run the batch on that agent's own model and role prompt. With no agent named, every task runs on your own model, so N tasks cost roughly N times what doing one yourself would. The saving is your context, not tokens -- fan out when the work is genuinely parallel, not by default.",
    ],
    parameters: Type.Object({
      agent: Type.Optional(
        Type.String({
          description: agents.length
            ? `Named agent to run every task in this call as. One of: ${agents.map((a) => a.name).join(", ")}. Omit to run on your own model with read-only tools.`
            : "Named agent to run every task as. None are configured, so omit this.",
        }),
      ),
      context: Type.Optional(
        Type.String({
          description:
            "Shared background prepended to every task below (project layout, what you're trying to find, etc.)",
        }),
      ),
      tasks: Type.Array(Type.String(), {
        minItems: 1,
        maxItems: MAX_CONCURRENCY,
        description:
          "One self-contained task per subagent. Each becomes a fresh pi run.",
      }),
    }),
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      const realBin = process.env.PI_REAL_BIN;
      if (!realBin) {
        return {
          content: [
            {
              type: "text",
              text: "task: $PI_REAL_BIN is not set. This tool only works when pi is launched through the sandbox wrapper (nix/pkgs/pi-wrapper), which exports it.",
            },
          ],
          details: {},
        };
      }

      let agent: Agent | undefined;
      if (params.agent) {
        agent = agents.find((a) => a.name === params.agent);
        if (!agent) {
          const available = agents.map((a) => a.name).join(", ") || "none";
          return {
            content: [
              {
                type: "text",
                text: `task: no agent named "${params.agent}". Available: ${available}.`,
              },
            ],
            details: {},
          };
        }
      }

      const model = resolveModel(agent, ctx);
      if (!model) {
        return {
          content: [
            {
              type: "text",
              text: "task: no model is selected, so there is nothing to run subagents on.",
            },
          ],
          details: {},
        };
      }

      const args = [
        "--tools",
        agent?.tools ?? SUBAGENT_TOOLS,
        "--model",
        model,
        "--mode",
        "json",
        // Keeps a fan-out of throwaway research runs out of the session tree.
        "--no-session",
      ];
      // Takes the text itself, not only a path (resolvePromptInput in pi's
      // core/resource-loader.js falls through to the literal string), so the
      // role prompt needs no temp file inside the sandbox.
      if (agent?.systemPrompt) {
        args.push("--append-system-prompt", agent.systemPrompt);
      }

      // pi's grammar is `pi [options] [@files...] [messages...]` with no `--`
      // terminator, so a model-authored task opening with -, -- or @ is read as
      // a flag or a filename and the subagent exits 1 before it runs. The
      // preamble is unconditional so the first argv word is never the task's.
      const prefix = params.context
        ? `Context:\n${params.context}\n\nTask:\n`
        : "Task:\n";
      const startedAt = Date.now();
      // Colons and dots out, matching the shape pi gives its own session files,
      // so the directory sorts chronologically in a plain ls.
      const stamp = new Date().toISOString().replace(/[:.]/g, "-");

      // Seeded before the fan-out so the row is a complete board from the
      // first render, rather than tasks appearing as their children report.
      const results: TaskResult[] = params.tasks.map((task, index) => ({
        index,
        task,
        state: "running",
        summary: "",
        live: "",
        window: "",
        trail: [],
        tools: 0,
        startedAt,
        elapsedMs: 0,
        tokens: 0,
        cost: 0,
      }));

      const emit = (): void => {
        onUpdate?.({
          content: [
            {
              type: "text",
              text: results
                .map(
                  (r) =>
                    `[${r.index + 1}] ${r.state === "running" ? (r.status ?? "starting") : r.state}`,
                )
                .join("\n"),
            },
          ],
          details: { agent: agent?.name, model, results },
        });
      };
      emit();

      // Each status emits, which is what moves the rows on a host without
      // the spinner.
      const seat = statusSeat(ctx.modelRegistry);
      const statusCalls = new AbortController();
      const inFlight = new Set<number>();
      const tick = setInterval(() => {
        for (const r of results) {
          if (r.state !== "running" || !r.window || inFlight.has(r.index))
            continue;
          const raw = rawStatus(r);
          const window = r.window;
          r.window = "";
          if (!seat) {
            r.status = raw;
            continue;
          }
          inFlight.add(r.index);
          summarize(
            ctx.modelRegistry,
            seat,
            r.task,
            window,
            AbortSignal.any([
              statusCalls.signal,
              AbortSignal.timeout(STATUS_TIMEOUT_MS),
            ]),
          )
            .catch(() => undefined)
            .then((status) => {
              inFlight.delete(r.index);
              if (r.state !== "running") return;
              r.status = status ?? raw;
              emit();
            });
        }
        if (!seat) emit();
      }, STATUS_MS);

      // The tool row scrolls away once anything prints below it, so the same
      // rows stay pinned above the editor until the batch returns. Keyed by
      // call, since one turn can hold more than one task call. RPC drops
      // component factories (docs/rpc-extension-ui.md), hence the mode rather
      // than hasUI. The working row's spinner redraws the screen for as long
      // as the tool runs, which is what keeps the clocks moving.
      const widget = `task-${toolCallId}`;
      const pinned = ctx.mode === "tui";
      if (pinned)
        ctx.ui.setWidget(widget, (_tui, theme) => ({
          invalidate: () => {},
          render: (width: number) =>
            results.map((r) =>
              truncateToWidth(
                `${theme.fg("accent", agent?.name ?? "task")} ${taskRow(r, theme)}`,
                width,
                theme.fg("dim", "..."),
              ),
            ),
        }));

      await runWithConcurrency<string, void>(
        params.tasks,
        MAX_CONCURRENCY,
        async (task, index) => {
          const r = results[index];
          const logFile = logFileFor(toolCallId, index, stamp);
          const outcome = await runChild(
            realBin,
            [...args, prefix + task],
            signal,
            (event) => {
              const type = event.type;
              // message_update is one event per token, tool_execution_update
              // repeats the whole accumulated result on every tick (pi
              // 0.84.3 docs/rpc.md), and agent_end repeats every message
              // already logged. All three are bulk and none is logged; the
              // first is still the only live window into a subagent's
              // reasoning between tool calls, so its deltas feed the live
              // tail the pinned rows narrate from.
              if (type === "message_update") {
                const block = event.assistantMessageEvent as
                  | { type?: string; delta?: string }
                  | undefined;
                // toolcall deltas stream argument JSON, not prose; the
                // trail's tool_execution_start row covers the call they
                // assemble.
                if (
                  block?.type === "thinking_start" ||
                  block?.type === "text_start"
                ) {
                  // A new content block replaces the last one's tail.
                  r.live = "";
                  addToWindow(r, "\n");
                } else if (
                  (block?.type === "thinking_delta" ||
                    block?.type === "text_delta") &&
                  typeof block.delta === "string"
                ) {
                  r.live = (r.live + block.delta).slice(-LIVE_TAIL);
                  addToWindow(r, block.delta);
                }
                return;
              }
              if (type === "tool_execution_update" || type === "agent_end")
                return;
              logEvent(logFile, { batch: toolCallId, task: index, event });

              if (type === "tool_execution_start") {
                r.tools++;
                r.activity = activityOf(
                  String(event.toolName ?? "?"),
                  event.args,
                );
                r.trail.push(r.activity);
                if (r.trail.length > MAX_TRAIL) r.trail.shift();
                addToWindow(r, `\ntool: ${r.activity}\n`);
                // Whatever the subagent reasoned to reach this call is spent
                // the moment the call runs; left in place it would pass stale
                // prose off as current once the call ends.
                r.live = "";
                emit();
              } else if (type === "tool_execution_end") {
                r.activity = undefined;
                emit();
              } else if (type === "message_end") {
                const message = event.message as
                  | {
                      role?: string;
                      usage?: {
                        totalTokens?: number;
                        cost?: { total?: number };
                      };
                    }
                  | undefined;
                // One assistant message is one billed request, so these sum
                // to the batch total across turns.
                if (message?.role === "assistant") {
                  r.tokens += message.usage?.totalTokens ?? 0;
                  r.cost += message.usage?.cost?.total ?? 0;
                }
                emit();
              }
            },
          );

          const result = classifyResult(
            outcome.events,
            outcome.code,
            outcome.aborted,
            outcome.timedOut,
          );
          const note = [result.error, outcome.stderr.trim().slice(-500)]
            .filter(Boolean)
            .join("\n");
          r.state = result.state === "success" ? "done" : "failed";
          r.summary = [result.text, note].filter(Boolean).join("\n");
          r.activity = undefined;
          // The details outlive the batch in the returned result, where done
          // rows show the summary; the spent tail has no place there.
          r.live = "";
          r.window = "";
          r.status = undefined;
          r.elapsedMs = Date.now() - r.startedAt;
          // Exit code, stderr and the bill are the parent's knowledge; none of
          // them appear in the child's own stream.
          logEvent(logFile, {
            batch: toolCallId,
            task: index,
            outcome: {
              state: r.state,
              result: result.state,
              code: outcome.code,
              aborted: outcome.aborted,
              timedOut: outcome.timedOut,
              tokens: r.tokens,
              cost: r.cost,
              elapsedMs: r.elapsedMs,
              stderr: outcome.stderr.trim().slice(-500),
            },
          });
          emit();
        },
      ).finally(() => {
        clearInterval(tick);
        statusCalls.abort();
        if (pinned) ctx.ui.setWidget(widget, undefined);
      });

      const summary = results
        .map(
          (r) =>
            `[${r.index + 1}] ${r.state === "done" ? "done" : "FAILED"}: ${r.task}\n${r.summary}`,
        )
        .join("\n\n---\n\n");

      return {
        content: [{ type: "text", text: summary }],
        details: { agent: agent?.name, model, results },
      };
    },

    // The default row renders the combined summary, so the outcome of a
    // three-subagent fan-out sits behind several screens of their prose. These
    // put the batch first: which tasks are running and what they are doing,
    // which came back and which failed, with the summaries behind ctrl+O.
    renderCall(args, theme, _context) {
      const count = Array.isArray(args.tasks) ? args.tasks.length : 0;
      let text =
        theme.fg("toolTitle", theme.bold("task ")) +
        theme.fg("muted", `${count} task${count === 1 ? "" : "s"}`);
      if (args.agent) text += ` ${theme.fg("accent", args.agent)}`;
      return new Text(text, 0, 0);
    },

    renderResult(result, { expanded }, theme, _context) {
      const details = result.details as
        | { agent?: string; model?: string; results?: TaskResult[] }
        | undefined;
      // The early argument errors carry no results array. Their own text is
      // the whole message.
      if (!details?.results) {
        const first = result.content[0];
        return new Text(first?.type === "text" ? first.text : "", 0, 0);
      }

      const { results, agent, model } = details;
      const running = results.filter((r) => r.state === "running").length;
      const tokens = results.reduce((n, r) => n + r.tokens, 0);
      const cost = results.reduce((n, r) => n + r.cost, 0);
      const head = [
        theme.fg(
          "muted",
          `${results.length} task${results.length === 1 ? "" : "s"}`,
        ),
        agent ? theme.fg("accent", agent) : undefined,
        model ? theme.fg("dim", model) : undefined,
        running ? theme.fg("warning", `${running} running`) : undefined,
        tokens ? theme.fg("dim", fmtTokens(tokens)) : undefined,
        // Providers that do not price a model report zero, and a $0.00 that
        // only means "unpriced" is worse than no column at all.
        cost > 0 ? theme.fg("dim", `$${cost.toFixed(2)}`) : undefined,
      ]
        .filter((part): part is string => part !== undefined)
        .join(theme.fg("dim", " · "));

      const lines = [head];
      for (const r of results) {
        lines.push(taskRow(r, theme));
        if (!expanded) continue;
        // While it runs the path it took is the only thing to show; once it
        // finishes, what it concluded matters more.
        if (r.state === "running")
          for (const step of r.trail)
            lines.push(theme.fg("dim", `      ${step}`));
        else if (r.summary) lines.push(theme.fg("dim", r.summary));
      }
      return new Text(lines.join("\n"), 0, 0);
    },
  });
}
