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
 *   - An agent named in `agents/*.md` carries its own model, tool allowlist
 *     and role prompt, so a scout can run on something cheap while the parent
 *     stays on the expensive model that needs the context. Unnamed tasks
 *     inherit the parent's model, which is the only safe default: a cloud
 *     parent fanning out to a small local model gets research too weak to act
 *     on, and a local parent fanning out to a cloud model spends real money
 *     N-at-a-time from a session whose whole point was that it cost nothing.
 *   - The child's NDJSON is read line by line while it runs, so the tool row
 *     reports what each subagent is doing now rather than only what it
 *     concluded ten minutes later. Every event also goes to its own file under
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
import {
  type ExtensionAPI,
  type ExtensionContext,
  getAgentDir,
  parseFrontmatter,
} from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";

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

interface Agent {
  name: string;
  description: string;
  tools: string;
  model?: string;
  systemPrompt: string;
}

interface TaskResult {
  index: number;
  task: string;
  state: "running" | "done" | "failed";
  summary: string;
  // The tool call in flight right now, absent while the subagent is thinking.
  activity?: string;
  trail: string[];
  tools: number;
  startedAt: number;
  elapsedMs: number;
  tokens: number;
  cost: number;
}

interface ChildOutcome {
  stdout: string;
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

// ~/.pi/agent/agents/*.md: frontmatter name/description/tools/model with the
// body as the role prompt. Read once at registration, like every other file
// under the extensions symlink, so an edit lands on /reload. Upstream also
// walks up for a project-scoped <repo>/.pi/agents; nothing has wanted a
// repo-specific researcher yet.
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

// Pull the final assistant message out of `--mode json`'s NDJSON event
// stream. Falls back to a raw stdout tail if the shape doesn't match --
// good enough for a personal tool; the raw text is still useful either way.
function lastAssistantText(stdout: string): string {
  const lines = stdout.split("\n").filter(Boolean);
  for (let i = lines.length - 1; i >= 0; i--) {
    let event: unknown;
    try {
      event = JSON.parse(lines[i]);
    } catch {
      continue;
    }
    const e = event as { type?: string; message?: { content?: unknown } };
    if (e?.type !== "message_end" || !Array.isArray(e.message?.content))
      continue;
    const text = (e.message.content as Array<Record<string, unknown>>)
      .filter((p) => p?.type === "text" && typeof p.text === "string")
      .map((p) => p.text as string)
      .join("\n")
      .trim();
    if (text) return text;
  }
  const tail = stdout.trim();
  return tail
    ? `(unparsed output, last 500 chars)\n${tail.slice(-500)}`
    : "(no output)";
}

// Tasks are model-authored paragraphs. A collapsed row is a label for one,
// not the text of it, so it gets a single line's worth and no newlines.
function oneLine(text: string, limit = 80): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > limit ? `${flat.slice(0, limit - 3)}...` : flat;
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
    let stdout = "";
    let stderr = "";
    let buffer = "";
    let aborted = false;
    let timedOut = false;
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
      if (event && typeof event === "object")
        onEvent(event as Record<string, unknown>);
    };

    proc.stdout.on("data", (chunk) => {
      const text = String(chunk);
      stdout += text;
      buffer += text;
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) readLine(line);
    });
    proc.stderr.on("data", (chunk) => {
      stderr += String(chunk);
    });

    const finish = (code: number): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      signal?.removeEventListener("abort", onAbort);
      if (buffer.trim()) readLine(buffer);
      resolve({ stdout, stderr, code, aborted, timedOut });
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

      const model = agent?.model ?? subagentModel(ctx);
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
      const prefix = params.context ? `${params.context}\n\n` : "Task:\n";
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
        trail: [],
        tools: 0,
        startedAt,
        elapsedMs: 0,
        tokens: 0,
        cost: 0,
      }));

      const emit = (): void => {
        for (const r of results)
          if (r.state === "running") r.elapsedMs = Date.now() - r.startedAt;
        onUpdate?.({
          content: [
            {
              type: "text",
              text: results
                .map(
                  (r) =>
                    `[${r.index + 1}] ${r.state}${r.activity ? ` ${r.activity}` : ""}`,
                )
                .join("\n"),
            },
          ],
          details: { agent: agent?.name, model, results },
        });
      };
      emit();

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
              // already logged. All three are bulk, none of them says
              // anything the rest of the stream has not.
              if (
                type === "message_update" ||
                type === "tool_execution_update" ||
                type === "agent_end"
              )
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

          // pi reports a bad model id, a missing key and an extension load
          // failure on stderr and exits with empty stdout, which reads as
          // "(no output)" and names no cause.
          const killed = outcome.aborted || outcome.timedOut;
          const note = killed
            ? outcome.aborted
              ? "(cancelled; anything above is what it had reached)"
              : `(no result after ${TASK_TIMEOUT_MS / 60_000}m; anything above is what it had reached)`
            : outcome.code === 0
              ? ""
              : outcome.stderr.trim().slice(-500);
          const text = lastAssistantText(outcome.stdout);

          r.state = outcome.code === 0 && !killed ? "done" : "failed";
          r.summary = note ? `${text}\n${note}` : text;
          r.activity = undefined;
          r.elapsedMs = Date.now() - r.startedAt;
          // Exit code, stderr and the bill are the parent's knowledge; none of
          // them appear in the child's own stream.
          logEvent(logFile, {
            batch: toolCallId,
            task: index,
            outcome: {
              state: r.state,
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
      );

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
    // `run`/`done`/`FAILED` are words rather than glyphs so the state survives
    // without color, and the latter two match the wire format the model
    // already receives.
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
        const label =
          r.state === "running"
            ? theme.fg("warning", "run   ")
            : r.state === "done"
              ? theme.fg("success", "done  ")
              : theme.fg("error", "FAILED");
        const subject =
          r.state === "running"
            ? theme.fg("muted", r.activity ?? "thinking")
            : theme.fg("muted", oneLine(r.task));
        const trailing =
          r.state === "running"
            ? theme.fg(
                "dim",
                `  ${r.tools} tool${r.tools === 1 ? "" : "s"}  ${fmtElapsed(r.elapsedMs)}`,
              )
            : r.elapsedMs
              ? theme.fg("dim", `  ${fmtElapsed(r.elapsedMs)}`)
              : "";
        lines.push(
          `${theme.fg("dim", `[${r.index + 1}]`)} ${label} ${subject}${trailing}`,
        );
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
