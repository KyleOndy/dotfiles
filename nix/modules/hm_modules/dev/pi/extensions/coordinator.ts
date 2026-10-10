/**
 * coordinator: spawn, watch and tear down agents that each get their own
 * worktree, and a forge VM when the spawn names a size.
 *
 * The sandbox cannot make a worktree beside its own, start a VM or start a pi
 * wider than itself, so none of that happens here. The coordinator writes a
 * request, and pi-broker (nix/pkgs/pi-broker), which the wrapper starts
 * outside the sandbox for `pi --coordinator`, does the work and records state
 * this reads back. A child started by the broker gets report_result, which is
 * the only thing it can write that the coordinator reads, and, when it holds
 * a VM, forge_boot, which asks the broker to boot it.
 *
 * Silent unless the wrapper exported PI_COORD_ROLE and PI_COORD_DIR, which it
 * does only for --coordinator and --coord-child. PI_COORD_FORGE is set when
 * the broker can give out VMs, and FORGE_INSTANCE when this child holds one.
 */

import { randomUUID } from "node:crypto";
import {
  existsSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { Type } from "typebox";
import type { ExtensionAPI, Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";

// The broker polls every 2s, so this is several of its rounds.
const RESPONSE_TIMEOUT_MS = 20_000;
const WAIT_POLL_MS = 5_000;
// The broker polls every 2s, so rereading state/ faster shows nothing new.
const WIDGET_POLL_MS = 2_000;
const MAX_WAIT_MINUTES = 120;
// forge's own VM_TIMEOUT is 10m, and the cache may need booting first.
const BOOT_TIMEOUT_MS = 15 * 60_000;
// States after which an agent will not change again without a new request.
const SETTLED = new Set(["failed", "exited", "done", "torn-down"]);
// pi's --thinking levels, which pi-broker checks against the same list.
const LEVELS = [
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
] as const;

interface AgentState {
  agent: string;
  state: string;
  instance?: string;
  size?: string;
  base?: string;
  branch?: string;
  worktree?: string;
  window?: string;
  vm?: string;
  error?: string;
  updated?: string;
  result: boolean;
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(new Error("cancelled"));
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        reject(new Error("cancelled"));
      },
      { once: true },
    );
  });
}

function text(value: string) {
  return { content: [{ type: "text" as const, text: value }], details: {} };
}

function coordinatorTools(pi: ExtensionAPI, dir: string, forge: boolean) {
  const readState = (agent: string): AgentState | undefined => {
    const file = join(dir, "state", `${agent}.json`);
    if (!existsSync(file)) return undefined;
    const state = JSON.parse(readFileSync(file, "utf8")) as AgentState;
    state.result = existsSync(join(dir, "agents", agent, "result.md"));
    return state;
  };

  const allStates = (): AgentState[] => {
    const stateDir = join(dir, "state");
    if (!existsSync(stateDir)) return [];
    // APFS lists in no fixed order, and the pinned rows would reshuffle.
    return readdirSync(stateDir)
      .filter((f) => f.endsWith(".json"))
      .sort()
      .map((f) => readState(f.slice(0, -5)))
      .filter((s): s is AgentState => s !== undefined);
  };

  const describe = (s: AgentState): string =>
    [
      `${s.agent}: ${s.state}${s.result ? ", result reported" : ""}`,
      s.instance &&
        `  forge instance ${s.instance} (${s.size})${s.vm ? `, VM ${s.vm}` : ""}`,
      s.worktree && `  worktree ${s.worktree}, branch ${s.branch}`,
      s.error && `  error: ${s.error}`,
    ]
      .filter(Boolean)
      .join("\n");

  const row = (s: AgentState, theme: Theme): string => {
    const color =
      s.state === "failed" || s.state === "exited"
        ? "error"
        : s.result || s.state === "done"
          ? "success"
          : "warning";
    return [
      theme.fg("accent", s.agent),
      theme.fg(color, s.state),
      s.result && theme.fg("success", "result reported"),
      s.error && theme.fg("dim", s.error),
    ]
      .filter(Boolean)
      .join("  ");
  };

  // agent_status answers only when the model asks, and its answer scrolls
  // away, so every agent not yet torn down stays pinned above the editor.
  // Polled, since state/ is the broker's only channel. Component factories
  // are terminal-only (docs/rpc-extension-ui.md), hence the mode.
  let poll: ReturnType<typeof setInterval> | undefined;
  pi.on("session_start", (_event, ctx) => {
    if (ctx.mode !== "tui") return;
    let shown = "";
    const refresh = (): void => {
      // This runs outside any tool call, so nothing would report a throw. A
      // state file that does not parse shows up through agent_status.
      let states: AgentState[];
      try {
        states = allStates().filter((s) => s.state !== "torn-down");
      } catch {
        return;
      }
      const key = JSON.stringify(states);
      if (key === shown) return;
      shown = key;
      ctx.ui.setWidget(
        "coordinator",
        states.length === 0
          ? undefined
          : (_tui, theme) => ({
              invalidate: () => {},
              render: (width: number) =>
                states.map((s) =>
                  truncateToWidth(row(s, theme), width, theme.fg("dim", "...")),
                ),
            }),
      );
    };
    clearInterval(poll);
    refresh();
    poll = setInterval(refresh, WIDGET_POLL_MS);
  });
  pi.on("session_shutdown", () => clearInterval(poll));

  // Written under a dot name the broker's *.json glob skips, then renamed,
  // so it never reads half a request.
  const request = async (
    body: Record<string, unknown>,
    signal?: AbortSignal,
  ): Promise<{ ok: boolean; message: string }> => {
    if (!existsSync(join(dir, "broker.pid"))) {
      throw new Error(
        `No broker is running for ${dir}. Restart with 'pi --coordinator=<id>' to reattach.`,
      );
    }
    const id = randomUUID();
    const tmp = join(dir, "requests", `.${id}.tmp`);
    writeFileSync(tmp, JSON.stringify(body));
    renameSync(tmp, join(dir, "requests", `${id}.json`));

    const response = join(dir, "responses", `${id}.json`);
    const deadline = Date.now() + RESPONSE_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (existsSync(response)) {
        return JSON.parse(readFileSync(response, "utf8"));
      }
      await sleep(250, signal);
    }
    throw new Error(
      `The broker did not answer within ${RESPONSE_TIMEOUT_MS / 1000}s; see ${join(dir, "broker.log")}.`,
    );
  };

  const size = Type.Optional(
    Type.Union(
      [Type.Literal("small"), Type.Literal("large"), Type.Literal("xlarge")],
      {
        description:
          "The agent's forge VM; none when omitted. small: 2 CPUs, 4GiB, one workload cluster. large: 4 CPUs, 8GiB, two workload clusters. xlarge: 8 CPUs, 16GiB, three or more workload clusters.",
      },
    ),
  );

  pi.registerTool({
    name: "spawn_agent",
    label: "Spawn agent",
    description: forge
      ? "Start an agent in its own git worktree and branch, in a new tmux window, with its own forge VM when given a size. The VM starts stopped: the agent boots it with forge_boot, then runs 'forge up' itself. Returns once the request is accepted."
      : "Start an agent in its own git worktree and branch, in a new tmux window. Returns once the request is accepted.",
    promptSnippet: "Spawn an agent with its own worktree and branch",
    promptGuidelines: [
      "The agent name becomes the branch and worktree name, prefixed with the ticket id when your own branch starts with one (DEV-123-), so make it short and descriptive: lowercase letters, digits, '.', '_' and '-'.",
      "The task is the agent's whole brief. It sees none of this conversation, so say what to do, what done looks like, and what to leave alone.",
      "After spawning, use agent_wait rather than polling agent_status in a loop.",
      ...(forge
        ? [
            "Give a size only when the task needs kind clusters or the forge docker daemon: an agent spawned without one can never get a VM. small covers one workload cluster, large two or heavy workloads, xlarge three or more each running a full stack.",
            "You hold no forge VM yourself, so work that needs kind clusters goes to an agent spawned with a size.",
          ]
        : []),
    ],
    parameters: Type.Object({
      agent: Type.String({
        description:
          "Agent name, which is also its branch and worktree name, after any ticket prefix.",
      }),
      task: Type.String({
        description: "The agent's full brief, sent as its first message.",
      }),
      ...(forge ? { size } : {}),
      base: Type.Optional(
        Type.String({
          description:
            "Commit or branch to start from. Defaults to the coordinator's HEAD.",
        }),
      ),
      model: Type.Optional(
        Type.String({
          description:
            "The agent's model as provider/id, optionally with a :level suffix taking one of the thinking levels. Defaults to this host's spawn seat, else your own model.",
        }),
      ),
      thinking: Type.Optional(
        Type.Union(
          LEVELS.map((level) => Type.Literal(level)),
          {
            description:
              "How hard the agent reasons, from off (none) through minimal, low, medium, high and xhigh to max (the most the model allows). Beats a :level suffix on the model. Defaults to that suffix, else pi's default level.",
          },
        ),
      ),
    }),
    async execute(_toolCallId, params, signal) {
      const r = await request({ op: "spawn", ...params }, signal);
      if (!r.ok) throw new Error(r.message);
      return text(r.message);
    },
  });

  pi.registerTool({
    name: "agent_status",
    label: "Agent status",
    description:
      "Show each spawned agent's state, worktree, any forge instance, and whether it has reported a result.",
    parameters: Type.Object({
      agent: Type.Optional(
        Type.String({ description: "One agent; all of them when omitted." }),
      ),
    }),
    async execute(_toolCallId, params) {
      const states = params.agent
        ? [readState(params.agent)].filter(
            (s): s is AgentState => s !== undefined,
          )
        : allStates();
      if (states.length === 0) {
        return text(params.agent ? `No agent ${params.agent}.` : "No agents.");
      }
      return text(states.map(describe).join("\n\n"));
    },
  });

  pi.registerTool({
    name: "agent_wait",
    label: "Wait for agents",
    description:
      "Block until one of the given agents reports a result or stops (failed, exited, torn down), or the timeout passes.",
    parameters: Type.Object({
      agents: Type.Optional(
        Type.Array(Type.String(), {
          description:
            "Agents to wait on. Defaults to every agent that has neither reported nor stopped.",
        }),
      ),
      timeout_minutes: Type.Optional(
        Type.Number({
          minimum: 1,
          maximum: MAX_WAIT_MINUTES,
          description: "Default 30.",
        }),
      ),
    }),
    async execute(_toolCallId, params, signal, onUpdate) {
      const settled = (s: AgentState | undefined) =>
        s === undefined || s.result || SETTLED.has(s.state);
      const names =
        params.agents ??
        allStates()
          .filter((s) => !settled(s))
          .map((s) => s.agent);
      if (names.length === 0) return text("No agent is still working.");

      const deadline = Date.now() + (params.timeout_minutes ?? 30) * 60_000;
      while (Date.now() < deadline) {
        const states = names.map((n) => ({ name: n, state: readState(n) }));
        const ready = states.filter((s) => settled(s.state));
        if (ready.length > 0) {
          return text(
            ready
              .map((s) => (s.state ? describe(s.state) : `${s.name}: unknown`))
              .join("\n\n"),
          );
        }
        onUpdate?.({
          content: [
            {
              type: "text",
              text: states
                .map((s) => `${s.name}: ${s.state?.state}`)
                .join(", "),
            },
          ],
          details: {},
        });
        await sleep(WAIT_POLL_MS, signal);
      }
      return text(
        `Still working after ${params.timeout_minutes ?? 30}m: ${names.join(", ")}.`,
      );
    },
  });

  pi.registerTool({
    name: "agent_result",
    label: "Agent result",
    description: "Read the result an agent reported with report_result.",
    parameters: Type.Object({
      agent: Type.String(),
    }),
    async execute(_toolCallId, params) {
      const file = join(dir, "agents", params.agent, "result.md");
      if (!existsSync(file)) {
        throw new Error(`${params.agent} has not reported a result.`);
      }
      return text(readFileSync(file, "utf8"));
    },
  });

  pi.registerTool({
    name: "agent_teardown",
    label: "Tear down agent",
    description:
      "Close an agent's tmux window and delete any forge VM it holds. Keeps its branch, and keeps its worktree unless remove_worktree is set.",
    promptGuidelines: [
      "Tear an agent down only once its result has been read and acted on, or when the user asks: its window, and any VM, is gone for good.",
      "remove_worktree fails safe: git refuses to remove a worktree with uncommitted changes, and the branch is always kept.",
    ],
    parameters: Type.Object({
      agent: Type.String(),
      remove_worktree: Type.Optional(Type.Boolean()),
    }),
    async execute(_toolCallId, params, signal) {
      const r = await request({ op: "teardown", ...params }, signal);
      if (!r.ok) throw new Error(r.message);
      return text(r.message);
    },
  });

  // The human's path to agent_teardown, which needs no model turn, since the
  // model may be what has gone wrong. An agent_wait on a torn-down agent
  // returns, so the model still learns of it.
  const FLAGS = ["--settled", "--remove-worktree"];
  pi.registerCommand("teardown", {
    description:
      "Tear down agents by name, or --settled for every done, exited or failed one. --remove-worktree also removes worktrees git considers clean.",
    // pi replaces the whole argument text with the chosen value, so the
    // words before the one being completed are carried over.
    getArgumentCompletions: (prefix) => {
      const before = prefix.slice(0, prefix.lastIndexOf(" ") + 1);
      const word = prefix.slice(before.length);
      let names: string[];
      try {
        names = allStates()
          .filter((s) => s.state !== "torn-down")
          .map((s) => s.agent);
      } catch {
        names = [];
      }
      const items = [...names, ...FLAGS]
        .filter((n) => n.startsWith(word))
        .map((n) => ({ value: before + n, label: n }));
      return items.length > 0 ? items : null;
    },
    handler: async (args, ctx) => {
      const words = args.trim().split(/\s+/).filter(Boolean);
      const unknown = words.filter(
        (w) => w.startsWith("-") && !FLAGS.includes(w),
      );
      const agents = new Set(words.filter((w) => !w.startsWith("-")));
      if (words.includes("--settled"))
        for (const s of allStates())
          if (SETTLED.has(s.state) && s.state !== "torn-down")
            agents.add(s.agent);
      if (unknown.length > 0 || agents.size === 0) {
        ctx.ui.notify(
          unknown.length > 0
            ? `teardown: unknown ${unknown.join(" ")}. Usage: /teardown <agent>... | --settled [--remove-worktree]`
            : "teardown: no agents to tear down",
          "warning",
        );
        return;
      }
      const remove_worktree = words.includes("--remove-worktree");
      const lines = await Promise.all(
        [...agents].map(async (agent) => {
          try {
            const r = await request({ op: "teardown", agent, remove_worktree });
            return { ok: r.ok, line: `${agent}: ${r.message}` };
          } catch (err) {
            return {
              ok: false,
              line: `${agent}: ${err instanceof Error ? err.message : String(err)}`,
            };
          }
        }),
      );
      ctx.ui.notify(
        lines.map((l) => l.line).join("\n"),
        lines.every((l) => l.ok) ? "info" : "error",
      );
    },
  });
}

function forgeBoot(pi: ExtensionAPI, dir: string) {
  pi.registerTool({
    name: "forge_boot",
    label: "Boot forge VM",
    description:
      "Boot your own forge VM, which starts stopped. The sandbox cannot boot it, so the broker does. Returns once it is running or has failed; takes a few minutes.",
    promptSnippet: "Boot your forge VM, then run 'forge up' for clusters",
    promptGuidelines: [
      "Call forge_boot only when the task needs kind clusters or the forge docker daemon; a task that does not leaves the VM stopped.",
      "forge_boot starts the VM and nothing else. Run 'forge up' afterwards to build the clusters; forge down, status and up all work from inside the sandbox.",
    ],
    parameters: Type.Object({}),
    async execute(_toolCallId, _params, signal) {
      const reply = join(dir, "boot.json");
      rmSync(reply, { force: true });
      writeFileSync(join(dir, "boot.request"), "");
      const deadline = Date.now() + BOOT_TIMEOUT_MS;
      while (Date.now() < deadline) {
        if (existsSync(reply)) {
          const r = JSON.parse(readFileSync(reply, "utf8"));
          if (!r.ok) throw new Error(r.message);
          return text(r.message);
        }
        await sleep(WAIT_POLL_MS, signal);
      }
      throw new Error(
        `No answer from the broker after ${BOOT_TIMEOUT_MS / 60_000}m. Report it with report_result; the coordinator's agent_status shows the VM state.`,
      );
    },
  });
}

function childTools(pi: ExtensionAPI, dir: string, forge: boolean) {
  if (forge) forgeBoot(pi, dir);

  pi.registerTool({
    name: "report_result",
    label: "Report result",
    description:
      "Hand your result to the coordinator that spawned you. Call it once the task is done or cannot be done; calling again replaces the earlier report.",
    promptSnippet: "Report your result to the coordinator",
    promptGuidelines: [
      "The coordinator sees only what report_result carries, not this conversation.",
    ],
    parameters: Type.Object({
      summary: Type.String({
        description:
          "Markdown: what was done, what was verified and how, commits on your branch, and anything left open.",
      }),
    }),
    async execute(_toolCallId, params) {
      const file = join(dir, "result.md");
      writeFileSync(`${file}.tmp`, params.summary);
      renameSync(`${file}.tmp`, file);
      return text("Reported. The coordinator can read it now.");
    },
  });
}

export default function (pi: ExtensionAPI) {
  const role = process.env.PI_COORD_ROLE;
  const dir = process.env.PI_COORD_DIR;
  if (!dir) return;
  if (role === "coordinator")
    coordinatorTools(pi, dir, process.env.PI_COORD_FORGE === "1");
  else if (role === "child")
    childTools(pi, dir, Boolean(process.env.FORGE_INSTANCE));
}
