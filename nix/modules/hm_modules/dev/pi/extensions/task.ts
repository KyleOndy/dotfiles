/**
 * task: parallel read-only subagents for the pi coding agent.
 *
 * pi has no built-in subagent tool (the upstream docs say so explicitly),
 * but its SDK/extension API is meant for exactly this: a custom tool whose
 * execute() spawns nested pi runs. This registers `task`: the model can
 * hand off several independent, read-heavy jobs (explore a directory,
 * summarize a file, answer a question about the codebase) to parallel
 * one-shot subagents, and gets back a combined summary instead of burning
 * its own context on the exploration.
 *
 * Subagent mechanics:
 *   - Each task runs as `$PI_REAL_BIN -p --mode json <task>`. PI_REAL_BIN is
 *     exported by nix/pkgs/pi-wrapper/wrapper.sh -- it points at the real,
 *     unwrapped pi binary. Spawning that directly (instead of re-invoking
 *     the `pi` sandbox wrapper) means a subagent does NOT open a second,
 *     redundant srt/bwrap/sandbox-exec layer: OS-level sandboxes confine
 *     the whole process tree, so a plain child of the already-sandboxed pi
 *     process inherits the same confinement for free.
 *   - Subagents are read-only (--tools read,grep,find,ls): no edit/write/
 *     bash. We deliberately skipped oh-my-pi's worktree isolation (real
 *     complexity for a personal tool) -- read-only access sidesteps the
 *     failure mode isolation exists to solve (parallel subagents racing to
 *     edit the same files) without needing it.
 *   - Subagents inherit the parent's model. Both mismatches are bad in
 *     their own way: a cloud parent fanning out to a small local model
 *     gets research too weak to act on, and a local parent fanning out to
 *     a cloud model spends real money N-at-a-time from a session whose
 *     whole point was that it cost nothing.
 *   - No isolation/schema/typed-output beyond a plain text summary per
 *     task. If that ever stops being enough, revisit -- it hasn't been
 *     needed yet.
 */

import { Type } from "typebox";
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

// Matches the local model server's --prompt-concurrency 3 (mlx-openai-server
// launchd config, nix/hosts/trex/home.nix) -- no point queuing more subagents
// than it will actually run in parallel. Applied to cloud fan-out too: 3
// independent read-only explorations is already a wide net.
const MAX_CONCURRENCY = 3;
const SUBAGENT_TOOLS = "read,grep,find,ls";

interface TaskResult {
  index: number;
  task: string;
  ok: boolean;
  summary: string;
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

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "task",
    label: "Task",
    description:
      "Delegate independent, read-only exploration tasks to parallel subagents running on your own model.",
    promptSnippet:
      "Fan out independent, read-heavy work (explore dirs, summarize files, answer questions about the codebase) to parallel subagents",
    promptGuidelines: [
      "Use for independent work you can fully describe up front -- exploring several directories, summarizing multiple files, running the same kind of investigation across different inputs.",
      "Each task runs as its own one-shot pi session with no access to this conversation; put everything it needs in `context` (shared across all tasks) or the task text itself.",
      "Subagents are read-only (read/grep/find/ls) -- they cannot edit files or run bash. Use them for research, not for making changes.",
      "Each subagent runs on your own model, so N tasks cost roughly N times what doing one yourself would. The saving is your context, not tokens -- fan out when the work is genuinely parallel, not by default.",
    ],
    parameters: Type.Object({
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
          "One self-contained task per subagent. Each becomes a fresh pi -p run.",
      }),
    }),
    async execute(_toolCallId, params, signal, onUpdate, ctx) {
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

      const model = subagentModel(ctx);
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

      // pi's grammar is `pi [options] [@files...] [messages...]` with no `--`
      // terminator, so a model-authored task opening with -, -- or @ is read as
      // a flag or a filename and the subagent exits 1 before it runs. The
      // preamble is unconditional so the first argv word is never the task's.
      const prefix = params.context ? `${params.context}\n\n` : "Task:\n";
      let completed = 0;

      const results = await runWithConcurrency<string, TaskResult>(
        params.tasks,
        MAX_CONCURRENCY,
        async (task, index) => {
          let result: TaskResult;
          try {
            const res = await pi.exec(
              realBin,
              [
                "--tools",
                SUBAGENT_TOOLS,
                "--model",
                model,
                "--mode",
                "json",
                prefix + task,
              ],
              { signal },
            );
            // pi reports a bad model id, a missing key and an extension load
            // failure on stderr and exits with empty stdout, which reads as
            // "(no output)" and names no cause.
            const failure = res.code === 0 ? "" : res.stderr.trim().slice(-500);
            result = {
              index,
              task,
              ok: res.code === 0,
              summary: failure
                ? `${lastAssistantText(res.stdout)}\n${failure}`
                : lastAssistantText(res.stdout),
            };
          } catch (err) {
            result = {
              index,
              task,
              ok: false,
              summary: `error: ${err instanceof Error ? err.message : String(err)}`,
            };
          }
          completed++;
          onUpdate?.({
            content: [
              {
                type: "text",
                text: `[${completed}/${params.tasks.length}] ${result.ok ? "done" : "FAILED"}: ${task}`,
              },
            ],
          });
          return result;
        },
      );

      const summary = results
        .map(
          (r) =>
            `[${r.index + 1}] ${r.ok ? "done" : "FAILED"}: ${r.task}\n${r.summary}`,
        )
        .join("\n\n---\n\n");

      return {
        content: [{ type: "text", text: summary }],
        details: { results },
      };
    },
  });
}
