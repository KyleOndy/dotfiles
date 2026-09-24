/**
 * coordinator: spawn, watch and tear down agents that each get their own
 * worktree and forge VM.
 *
 * The sandbox cannot make a worktree beside its own, start a VM or start a pi
 * wider than itself, so none of that happens here. The coordinator writes a
 * request, and pi-broker (nix/pkgs/pi-broker), which the wrapper starts
 * outside the sandbox for `pi --coordinator`, does the work and records state
 * this reads back. A child started by the broker gets report_result, which is
 * the only thing it can write that the coordinator reads, and forge_boot,
 * which asks the broker to boot the child's own VM.
 *
 * Silent unless the wrapper exported PI_COORD_ROLE and PI_COORD_DIR, which it
 * does only for --coordinator and --coord-child.
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
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// The broker polls every 2s, so this is several of its rounds.
const RESPONSE_TIMEOUT_MS = 20_000;
const WAIT_POLL_MS = 5_000;
const MAX_WAIT_MINUTES = 120;
// forge's own VM_TIMEOUT is 10m, and the cache may need booting first.
const BOOT_TIMEOUT_MS = 15 * 60_000;
// States after which an agent will not change again without a new request.
const SETTLED = new Set(["failed", "exited", "done", "torn-down"]);

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

function coordinatorTools(pi: ExtensionAPI, dir: string) {
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
    return readdirSync(stateDir)
      .filter((f) => f.endsWith(".json"))
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

  pi.registerTool({
    name: "spawn_agent",
    label: "Spawn agent",
    description:
      "Start an agent in its own git worktree and branch, with its own forge VM, in a new tmux window. The VM starts stopped: the agent boots it with forge_boot only if its task needs kind clusters, then runs 'forge up' itself. Returns once the request is accepted.",
    promptSnippet: "Spawn an agent with its own worktree, branch and forge VM",
    promptGuidelines: [
      "The agent name becomes the branch and worktree name, prefixed with the ticket id when your own branch starts with one (DEV-123-), so make it short and descriptive: lowercase letters, digits, '.', '_' and '-'.",
      "The task is the agent's whole brief. It sees none of this conversation, so say what to do, what done looks like, and what to leave alone.",
      "Use size large only when the task needs two workload clusters or heavy workloads; small is the default and leaves room for more agents.",
      "After spawning, use agent_wait rather than polling agent_status in a loop.",
      "You hold no forge VM yourself. Work that needs kind clusters goes to a spawned agent, and its brief should say so, since the agent decides whether to boot its VM.",
    ],
    parameters: Type.Object({
      agent: Type.String({
        description:
          "Agent name, which is also its branch and worktree name, after any ticket prefix.",
      }),
      task: Type.String({
        description: "The agent's full brief, sent as its first message.",
      }),
      size: Type.Optional(
        Type.Union([Type.Literal("small"), Type.Literal("large")], {
          description:
            "small: 2 CPUs, 4GiB, one workload cluster. large: 4 CPUs, 8GiB, two workload clusters.",
        }),
      ),
      base: Type.Optional(
        Type.String({
          description:
            "Commit or branch to start from. Defaults to the coordinator's HEAD.",
        }),
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
      "Show each spawned agent's state, forge instance, worktree, and whether it has reported a result.",
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
      "Close an agent's tmux window and delete its forge VM. Keeps its branch, and keeps its worktree unless remove_worktree is set.",
    promptGuidelines: [
      "Tear an agent down only once its result has been read and acted on, or when the user asks: the VM is gone for good.",
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
}

function childTools(pi: ExtensionAPI, dir: string) {
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
  if (role === "coordinator") coordinatorTools(pi, dir);
  else if (role === "child") childTools(pi, dir);
}
