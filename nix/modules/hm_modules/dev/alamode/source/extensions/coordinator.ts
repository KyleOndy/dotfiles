import { randomUUID } from "node:crypto";
import { createConnection } from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const LIMIT = 2 * 1024 * 1024;
const SETTLED = new Set(["idle", "closed", "lost", "failed", "waiting_input"]);

interface Agent {
  agent: string;
  state: string;
  workspace?: string;
  outcome?: { state: string; text: string; error?: string };
  error?: string;
  dialogs?: Record<
    string,
    { method: string; title: string; options?: string[] }
  >;
  report?: { text: string };
  question?: { text: string };
  // The tool the child last started, or "thinking"; meaningful only while
  // executing. supervisor.py strips control and format characters from it.
  activity?: string | null;
}

function request(
  body: Record<string, unknown>,
  signal?: AbortSignal,
): Promise<any> {
  const socket = process.env.ALAMODE_COORD_SOCKET;
  const token = process.env.ALAMODE_COORD_TOKEN;
  if (!socket || !token)
    throw new Error("Coordinator credentials are unavailable");
  const operation = { id: randomUUID(), ...body, token };
  const wire = JSON.stringify(operation) + "\n";
  if (Buffer.byteLength(wire) > LIMIT) throw new Error("Request exceeds 2 MiB");
  return new Promise((resolve, reject) => {
    const client = createConnection(socket);
    let response = Buffer.alloc(0);
    let finished = false;
    const finish = (error?: Error, value?: unknown) => {
      if (finished) return;
      finished = true;
      signal?.removeEventListener("abort", cancelled);
      client.destroy();
      if (error) reject(error);
      else resolve(value);
    };
    const cancelled = () =>
      finish(
        new Error(
          `Stopped waiting for operation ${operation.id}; the operation may still be running`,
        ),
      );
    signal?.addEventListener("abort", cancelled, { once: true });
    if (signal?.aborted) return cancelled();
    client.setTimeout(body.op === "forge_boot" ? 16 * 60_000 : 35_000, () =>
      finish(
        new Error(
          `Operation ${operation.id} timed out; inspect agent_status before sending new work`,
        ),
      ),
    );
    client.on("connect", () => client.write(wire));
    client.on("error", (error) => finish(error));
    client.on("end", () =>
      finish(
        new Error(
          `Broker disconnected during operation ${operation.id}; inspect status before retrying`,
        ),
      ),
    );
    client.on("data", (part) => {
      response = Buffer.concat([response, part]);
      if (response.length > LIMIT)
        return finish(new Error("Broker response exceeds 2 MiB"));
      const newline = response.indexOf(10);
      if (newline < 0) return;
      try {
        const reply = JSON.parse(response.subarray(0, newline).toString());
        if (!reply.ok || reply.data?.receipt === "failed") {
          finish(new Error(reply.error || reply.data.error));
        } else finish(undefined, reply.data);
      } catch (error) {
        finish(error as Error);
      }
    });
  });
}

// Every tool result reaches the model through here. Activity is the child's
// own text and is for the human's rows, so it never does.
function text(value: unknown) {
  return {
    content: [
      {
        type: "text" as const,
        text:
          typeof value === "string"
            ? value
            : JSON.stringify(
                value,
                (key, field) => (key === "activity" ? undefined : field),
                2,
              ),
      },
    ],
    details: {},
  };
}

// width is the longest agent name among the rows shown. Names match broker.py's
// NAME, so length is display width.
function describe(agent: Agent, width = 0): string {
  return (
    `${`${agent.agent}:`.padEnd(width + 1)} ${agent.state}${agent.outcome ? ` (${agent.outcome.state})` : ""}` +
    (agent.state === "executing" && agent.activity
      ? `  ${agent.activity}`
      : "") +
    (agent.question ? `\nQuestion: ${agent.question.text}` : "") +
    (agent.error ? `\n${agent.error}` : "") +
    (Object.keys(agent.dialogs || {}).length
      ? `\nDialogs: ${JSON.stringify(agent.dialogs)}`
      : "")
  );
}

function delay(milliseconds: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const cancel = () => {
      clearTimeout(timer);
      reject(new Error("Wait cancelled; the agent continues running"));
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", cancel);
      resolve();
    }, milliseconds);
    if (signal?.aborted) cancel();
    else signal?.addEventListener("abort", cancel, { once: true });
  });
}

export default function coordinator(pi: ExtensionAPI) {
  const role = process.env.ALAMODE_COORD_ROLE;
  if (!process.env.ALAMODE_COORD_SOCKET || !process.env.ALAMODE_COORD_TOKEN)
    return;
  if (role === "child") {
    pi.registerTool({
      name: "export_commits",
      label: "Export commits",
      description:
        "Offer committed work to the coordinator for validated import. Commit changes first. This preserves the child branch and does not modify the coordinator.",
      parameters: Type.Object({}),
      async execute(_id, _params, signal) {
        const status = await pi.exec("git", ["status", "--porcelain"], {
          signal,
        });
        if (status.code !== 0 || status.stdout.trim())
          throw new Error(
            "Commit changes before exporting; the workspace must be clean",
          );
        const head = await pi.exec("git", ["rev-parse", "HEAD"], { signal });
        if (head.code !== 0) throw new Error(head.stderr);
        const directory = mkdtempSync(join(tmpdir(), "alamode-export-"));
        try {
          const bundle = join(directory, "proposal.bundle");
          const result = await pi.exec(
            "git",
            ["bundle", "create", bundle, "HEAD"],
            { signal },
          );
          if (result.code !== 0) throw new Error(result.stderr);
          return text(
            await request(
              { op: "offer", bundle, tip: head.stdout.trim() },
              signal,
            ),
          );
        } finally {
          rmSync(directory, { recursive: true, force: true });
        }
      },
    });
    if (process.env.FORGE_INSTANCE)
      pi.registerTool({
        name: "forge_boot",
        label: "Boot Forge resource",
        description:
          "Ask the broker to boot this agent's assigned Forge VM, then run forge up in this workspace.",
        parameters: Type.Object({}),
        async execute(_id, _params, signal) {
          return text(await request({ op: "forge_boot" }, signal));
        },
      });
    for (const [name, op, description] of [
      [
        "report_result",
        "report",
        "Report findings to the coordinator. This report is separate from runtime completion and verification.",
      ],
      [
        "ask_coordinator",
        "question",
        "Ask the coordinator a question. The coordinator can send a follow-up instruction.",
      ],
    ]) {
      pi.registerTool({
        name,
        label: name,
        description,
        parameters: Type.Object({ message: Type.String() }),
        async execute(_id, params, signal) {
          return text(await request({ op, message: params.message }, signal));
        },
      });
    }
    return;
  }
  if (role !== "coordinator" && role !== "main") return;

  pi.registerTool({
    name: "spawn_agent",
    label: "Spawn agent",
    description:
      "Start an independent session and Git branch. Defaults to the coordinator launch snapshot. include_commits exports the coordinator's current committed HEAD inside its sandbox. Uncommitted changes require a commit first. Forge is optional and separate.",
    parameters: Type.Object({
      agent: Type.String(),
      task: Type.String(),
      include_commits: Type.Optional(Type.Boolean()),
      model: Type.Optional(Type.String()),
      size: Type.Optional(
        Type.Union([
          Type.Literal("small"),
          Type.Literal("large"),
          Type.Literal("xlarge"),
        ]),
      ),
      thinking: Type.Optional(
        Type.Union(
          ["off", "minimal", "low", "medium", "high", "xhigh", "max"].map(
            (level) => Type.Literal(level),
          ),
        ),
      ),
    }),
    async execute(_id, params, signal) {
      const body: Record<string, unknown> = { op: "spawn", ...params };
      let temporary: string | undefined;
      try {
        if (params.include_commits) {
          const status = await pi.exec("git", ["status", "--porcelain"], {
            signal,
          });
          if (status.code !== 0 || status.stdout.trim())
            throw new Error(
              "Commit coordinator changes before include_commits; the workspace must be clean",
            );
          const head = await pi.exec("git", ["rev-parse", "HEAD"], { signal });
          if (head.code !== 0) throw new Error(head.stderr);
          temporary = mkdtempSync(join(tmpdir(), "alamode-child-"));
          const bundle = join(temporary, "source.bundle");
          const result = await pi.exec(
            "git",
            ["bundle", "create", bundle, "HEAD"],
            { signal },
          );
          if (result.code !== 0) throw new Error(result.stderr);
          body.bundle = bundle;
          body.tip = head.stdout.trim();
        }
        return text(await request(body, signal));
      } finally {
        if (temporary) rmSync(temporary, { recursive: true, force: true });
      }
    },
  });

  for (const [name, op, description] of [
    [
      "agent_status",
      "status",
      "Read agent lifecycle, pending dialogs, reports and runtime outcomes.",
    ],
    [
      "agent_result",
      "result",
      "Read the runtime outcome and the agent's separate report. Verification is independent.",
    ],
    [
      "agent_interrupt",
      "interrupt",
      "Cancel active work, queued messages and dialogs. Preserve session and Git work.",
    ],
    [
      "agent_resume",
      "resume",
      "Reconnect or restart a lost or closed runtime using its existing session. No previous prompt is replayed.",
    ],
    [
      "agent_teardown",
      "teardown",
      "Close the runtime and release active capacity. Preserve the workspace and session.",
    ],
  ]) {
    pi.registerTool({
      name,
      label: name,
      description,
      parameters: Type.Object({
        agent: op === "status" ? Type.Optional(Type.String()) : Type.String(),
      }),
      async execute(_id, params, signal) {
        return text(await request({ op, agent: params.agent }, signal));
      },
    });
  }
  pi.registerTool({
    name: "agent_send",
    label: "Send agent instruction",
    description:
      "Send work to an idle agent, steer active work, or queue a follow-up. Answer pending dialogs first.",
    parameters: Type.Object({
      agent: Type.String(),
      message: Type.String(),
      mode: Type.Optional(
        Type.Union([Type.Literal("steer"), Type.Literal("follow_up")]),
      ),
    }),
    async execute(_id, params, signal) {
      return text(await request({ op: "send", ...params }, signal));
    },
  });
  pi.registerTool({
    name: "agent_integrate",
    label: "Integrate agent commits",
    description:
      "Import a child's exported, validated commits into this private coordinator branch. Requires a clean workspace. Conflicts remain available for resolution; the human source is unchanged.",
    parameters: Type.Object({ agent: Type.String() }),
    async execute(_id, params, signal) {
      const status = await pi.exec("git", ["status", "--porcelain"], {
        signal,
      });
      if (status.code !== 0 || status.stdout.trim())
        throw new Error(
          "Commit coordinator changes before integration; the workspace must be clean",
        );
      const admitted = await request(
        { op: "admit", agent: params.agent },
        signal,
      );
      const reference = `refs/alamode/admitted/${randomUUID()}`;
      const fetched = await pi.exec(
        "git",
        [
          "fetch",
          "--no-tags",
          "--no-auto-maintenance",
          admitted.bundle,
          `HEAD:${reference}`,
        ],
        { signal },
      );
      if (fetched.code !== 0) throw new Error(fetched.stderr);
      const tip = await pi.exec("git", ["rev-parse", reference], { signal });
      if (tip.code !== 0 || tip.stdout.trim() !== admitted.tip)
        throw new Error("Fetched proposal does not match the admitted commit");
      const integrated = await pi.exec(
        "git",
        ["cherry-pick", `${admitted.base}..${admitted.tip}`],
        { signal },
      );
      if (integrated.code !== 0)
        throw new Error(
          `Integration stopped; resolve or abort the cherry-pick in this workspace.\\n${integrated.stderr}`,
        );
      return text({
        tip: admitted.tip,
        commits: admitted.commits,
        output: integrated.stdout,
      });
    },
  });
  pi.registerTool({
    name: "agent_answer",
    label: "Answer agent dialog",
    description:
      "Answer or cancel a pending runtime dialog. confirm requires a boolean; other dialogs require text.",
    parameters: Type.Object({
      agent: Type.String(),
      dialog: Type.String(),
      value: Type.Optional(Type.Union([Type.String(), Type.Boolean()])),
      cancelled: Type.Optional(Type.Boolean()),
    }),
    async execute(_id, params, signal) {
      return text(await request({ op: "answer", ...params }, signal));
    },
  });
  pi.registerTool({
    name: "agent_wait",
    label: "Wait for agent",
    description:
      "Wait for completed work, a pending question, a dialog, or a lost runtime. Cancelling this wait does not interrupt the agent.",
    parameters: Type.Object({
      agent: Type.String(),
      minutes: Type.Optional(Type.Number({ minimum: 0, maximum: 120 })),
    }),
    async execute(_id, params, signal) {
      const deadline = Date.now() + (params.minutes ?? 10) * 60_000;
      while (true) {
        const state: Agent = await request(
          { op: "status", agent: params.agent },
          signal,
        );
        if (
          SETTLED.has(state.state) ||
          state.question ||
          Date.now() >= deadline
        )
          return text(state);
        await delay(1000, signal);
      }
    },
  });

  pi.registerCommand("agents", {
    description: "Show agents, outcomes and pending questions",
    async handler(_args, ctx) {
      try {
        const state = await request({ op: "status" });
        const agents = state.agents as Agent[];
        const width = Math.max(0, ...agents.map((agent) => agent.agent.length));
        ctx.ui.notify(
          agents.map((agent) => describe(agent, width)).join("\n") ||
            "No agents",
        );
      } catch (error) {
        ctx.ui.notify(String(error), "error");
      }
    },
  });
  pi.registerCommand("agent", {
    description:
      "Control a child: <name> send|steer|interrupt|resume|answer|close [message]",
    async handler(args, ctx) {
      try {
        const [agent, action, ...words] = args.trim().split(/\s+/);
        if (!agent || !action)
          throw new Error(
            "Usage: /agent <name> send|steer|interrupt|resume|answer|close [message]",
          );
        let body: Record<string, unknown> = { agent };
        if (action === "send" || action === "steer")
          body = {
            ...body,
            op: "send",
            mode: action === "steer" ? "steer" : "follow_up",
            message: words.join(" "),
          };
        else if (["interrupt", "resume", "close"].includes(action))
          body.op = action;
        else if (action === "answer") {
          const state: Agent = await request({ op: "status", agent });
          const entries = Object.entries(state.dialogs || {});
          if (!entries.length) throw new Error("No pending dialogs");
          const [dialog, question] = entries[0];
          const value =
            question.method === "confirm"
              ? await ctx.ui.confirm(question.title, "")
              : question.method === "select"
                ? await ctx.ui.select(question.title, question.options || [])
                : await ctx.ui.input(question.title);
          body = {
            ...body,
            op: "answer",
            dialog,
            value,
            cancelled: value === undefined,
          };
        } else throw new Error("Unknown agent action");
        ctx.ui.notify(JSON.stringify(await request(body)));
      } catch (error) {
        ctx.ui.notify(String(error), "error");
      }
    },
  });
  pi.registerCommand("teardown", {
    description:
      "Close agents while preserving their work; --settled closes only idle agents",
    async handler(args, ctx) {
      try {
        if (args.trim() && args.trim() !== "--settled")
          throw new Error("Usage: /teardown [--settled]");
        const state = await request({ op: "status" });
        for (const agent of state.agents as Agent[]) {
          if (
            agent.state === "closed" ||
            (args.trim() === "--settled" && agent.state !== "idle")
          )
            continue;
          await request({ op: "teardown", agent: agent.agent });
        }
        ctx.ui.notify(
          "Agent runtimes closed. Workspaces and sessions preserved.",
        );
      } catch (error) {
        ctx.ui.notify(String(error), "error");
      }
    },
  });

  let polling: ReturnType<typeof setInterval> | undefined;
  let refreshing = false;
  pi.on("session_start", (_event, ctx) => {
    clearInterval(polling);
    if (ctx.mode !== "tui") return;
    const refresh = async () => {
      if (refreshing) return;
      refreshing = true;
      try {
        const state = await request({ op: "status" });
        const agents = (state.agents as Agent[]).filter(
          (agent) => agent.state !== "closed",
        );
        const width = Math.max(0, ...agents.map((agent) => agent.agent.length));
        ctx.ui.setWidget(
          "coordinator",
          agents.length
            ? agents.map((agent) => describe(agent, width))
            : undefined,
        );
      } catch (error) {
        ctx.ui.setWidget("coordinator", [String(error)]);
      } finally {
        refreshing = false;
      }
    };
    void refresh();
    polling = setInterval(() => void refresh(), 2000);
  });
  pi.on("session_shutdown", () => clearInterval(polling));
  pi.on("before_agent_start", (event) => {
    event.systemPromptOptions.sections.coordinator =
      "# Coordinator\n\n" +
      "Child sessions survive this UI closing. Use agent_status to reconcile before spawning replacements. " +
      "A runtime outcome, an agent report and independent verification are separate facts. " +
      "Resume never replays interrupted work. Send an explicit instruction after examining the preserved state. " +
      "Grant changes require the human's trusted session launcher. Child tools cannot widen grants.";
  });
}
