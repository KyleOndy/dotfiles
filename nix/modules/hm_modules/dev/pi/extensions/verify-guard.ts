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
 *   ~/.pi/agent/verify.json   and the nearest .pi/verify.json between the
 *   session's cwd and its git root, inclusive
 *   { "enabled": true, "command": "make check" }
 * With no command configured the guard is inert rather than inventing one, so
 * a repo that has no verifier is not nagged about a command that cannot run.
 * The command runs from the directory holding the .pi/ it came from, or the
 * git root for a global one.
 *
 * The agent runs the verifier through the `verify` tool, never through bash,
 * so the exit code is the command's own. Scraping bash calls could not tell
 * `make check | tail; echo $?` (tail's status) from a real pass, and missed
 * a verifier split across two calls.
 *
 * "Unverified" means the worktree differs from the state the last green run
 * saw, or from the session's starting state before any run. The fingerprint
 * is HEAD plus the diff against it plus every untracked file's contents, so
 * a commit, a heredoc write and a python write all count, a write into $TMPDIR
 * does not, and reverting an edit clears it. Outside a git repo there is no
 * fingerprint and the guard is inert.
 */

import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { lstat, readFile, readlink } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";

interface VerifyGuardConfig {
  enabled: boolean;
  command: string | null;
}

const DEFAULT_CONFIG: VerifyGuardConfig = { enabled: true, command: null };

// Lines of verifier output returned to the model. The head of a nix or make
// run is progress noise; the failure is at the tail.
const OUTPUT_TAIL_LINES = 60;

function agentDir(): string {
  return process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent");
}

function readConfig(path: string): Partial<VerifyGuardConfig> | null {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(
      readFileSync(path, "utf-8"),
    ) as Partial<VerifyGuardConfig>;
  } catch (e) {
    console.error(`verify-guard: could not parse ${path}: ${e}`);
    return null;
  }
}

// Nearest .pi/verify.json from cwd up to root, inclusive. Returns the
// directory holding .pi/, which is where the command runs.
function findProjectConfig(
  cwd: string,
  root: string,
): { dir: string; config: Partial<VerifyGuardConfig> } | null {
  for (let dir = cwd; ; dir = dirname(dir)) {
    const config = readConfig(join(dir, ".pi", "verify.json"));
    if (config) return { dir, config };
    if (dir === root || dir === dirname(dir)) return null;
  }
}

export default function (pi: ExtensionAPI) {
  pi.registerFlag("no-verify-guard", {
    description: "Do not track whether the project's verifier has been run",
    type: "boolean",
    default: false,
  });

  let cfg = DEFAULT_CONFIG;
  let active = false;
  let gitRoot = "";
  let runDir = "";
  let toolRegistered = false;
  // Fingerprint of the last state the verifier passed on, or of the session's
  // starting state before any green run.
  let verifiedFingerprint = "";
  let stale = false;
  let verifyFailing = false;
  let verifyRuns = 0;
  let steeredThisEpisode = false;

  const git = async (args: string[]): Promise<string | null> => {
    const r = await pi.exec("git", args, { cwd: gitRoot });
    return r.code === 0 ? r.stdout : null;
  };

  // --no-textconv and --no-ext-diff keep the diff independent of git-crypt
  // and user diff drivers. null means git failed, which leaves state alone.
  const fingerprint = async (): Promise<string | null> => {
    const head = (await git(["rev-parse", "--verify", "-q", "HEAD"])) ?? "";
    const diff = await git([
      "diff",
      "HEAD",
      "--binary",
      "--no-textconv",
      "--no-ext-diff",
    ]);
    const untracked = await git(["ls-files", "-o", "--exclude-standard", "-z"]);
    if (diff === null || untracked === null) return null;
    const hash = createHash("sha256").update([head, diff].join("\0\0"));
    for (const file of untracked.split("\0").filter((f) => f !== "")) {
      const path = join(gitRoot, file);
      // A symlink counts by its target, as git would store it, so a dangling
      // one or one to a directory hashes like any other file. A path that
      // cannot be read (gone since ls-files, a nested repo's directory)
      // counts by name alone.
      const content = await lstat(path)
        .then((st) => (st.isSymbolicLink() ? readlink(path) : readFile(path)))
        .catch(() => "");
      hash.update(`\0\0${file}\0`).update(content);
    }
    return hash.digest("hex");
  };

  const state = (): string => {
    if (!active) return "off";
    if (verifyFailing) return stale ? "failed (changed since)" : "failed";
    if (stale) return "unverified changes";
    return verifyRuns === 0 ? "not run" : "current";
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
    };

    if (!stale && !verifyFailing) {
      ui.setWidget("verify-guard", undefined);
      ui.setStatus("verify-guard", `verify: ${state()}`);
      return;
    }

    ui.setStatus("verify-guard", undefined);
    // Width is only knowable here, and the configured command runs long
    // enough to wrap onto a second row without the truncation.
    ui.setWidget(
      "verify-guard",
      (_tui, theme) => ({
        invalidate: () => {},
        render: (width: number) => [
          truncateToWidth(
            (verifyFailing
              ? theme.fg("error", "verify: last run failed")
              : theme.fg("warning", "verify: unverified changes")) +
              theme.fg("dim", `  ${cfg.command}`),
            width,
            theme.fg("dim", "..."),
          ),
        ],
      }),
      { placement: "belowEditor" },
    );
  };

  const registerVerifyTool = (): void => {
    if (toolRegistered) return;
    toolRegistered = true;
    pi.registerTool({
      name: "verify",
      label: "Verify",
      description:
        "Run the project's configured verifier and return its exit code and the tail of its output.",
      promptSnippet:
        "Run the project's verifier (from .pi/verify.json) and report whether it passed",
      promptGuidelines: [
        "Use verify to run the project's verifier before calling work done. Do not run the verifier's command through bash: only a verify call clears verify-guard, and a bash pipeline can hide the real exit code.",
      ],
      parameters: Type.Object({}),
      async execute(_toolCallId, _params, signal, onUpdate) {
        if (!active || cfg.command === null) {
          throw new Error("verify: no verifier is configured for this repo.");
        }
        const before = await fingerprint();
        const started = Date.now();
        const elapsed = (): string =>
          `${Math.round((Date.now() - started) / 1000)}s`;
        const tick = setInterval(
          () =>
            onUpdate?.({
              content: [
                { type: "text", text: `running ${elapsed()}: ${cfg.command}` },
              ],
              details: undefined,
            }),
          1000,
        );
        let result: Awaited<ReturnType<typeof pi.exec>>;
        try {
          // exec 2>&1 before the command, not after it, so every stage of an
          // `a && b` chain lands in one ordered stream.
          result = await pi.exec("bash", ["-c", `exec 2>&1\n${cfg.command}`], {
            cwd: runDir,
            signal,
          });
        } finally {
          clearInterval(tick);
        }

        const lines = result.stdout.trimEnd().split("\n");
        const tail = lines.slice(-OUTPUT_TAIL_LINES).join("\n");
        const cut =
          lines.length > OUTPUT_TAIL_LINES
            ? `(last ${OUTPUT_TAIL_LINES} of ${lines.length} lines)\n`
            : "";
        const text = `exit ${result.code} after ${elapsed()} in ${runDir}\n${cut}${tail}`;

        verifyRuns++;
        if (result.code === 0 && !result.killed) {
          verifyFailing = false;
          steeredThisEpisode = false;
          // The state the command saw is the one it vouches for. A tree that
          // moved during the run stays stale.
          if (before !== null) verifiedFingerprint = before;
          const now = await fingerprint();
          if (now !== null) stale = now !== verifiedFingerprint;
          return { content: [{ type: "text", text }], details: undefined };
        }

        // A failing run withholds the steer: the agent has the output now,
        // and asking again produces the same report. The widget carries
        // `failed` until a run comes back green.
        verifyFailing = true;
        steeredThisEpisode = true;
        throw new Error(text);
      },
    });
  };

  pi.on("session_start", async (_event, ctx) => {
    active = false;
    if (pi.getFlag("no-verify-guard") === true) return;
    const top = await pi.exec("git", ["rev-parse", "--show-toplevel"], {
      cwd: ctx.cwd,
    });
    if (top.code !== 0) return;
    gitRoot = top.stdout.trim();

    const global = readConfig(join(agentDir(), "verify.json")) ?? {};
    const project = findProjectConfig(ctx.cwd, gitRoot);
    const merged = { ...global, ...project?.config };
    cfg = {
      enabled: merged.enabled ?? DEFAULT_CONFIG.enabled,
      command: merged.command ?? DEFAULT_CONFIG.command,
    };
    runDir = project?.dir ?? gitRoot;
    active = cfg.enabled && cfg.command !== null;
    if (!active) return;

    verifiedFingerprint = (await fingerprint()) ?? "";
    stale = false;
    verifyFailing = false;
    verifyRuns = 0;
    steeredThisEpisode = false;
    registerVerifyTool();
    showStatus(ctx);
  });

  pi.on("turn_end", async (event, ctx) => {
    if (!active) return;
    const now = await fingerprint();
    if (now !== null) stale = now !== verifiedFingerprint;
    showStatus(ctx);

    // Tool results in a turn_end mean the agent has another turn coming to act
    // on them, so it is still working and a nag would land mid-stride. A turn
    // carrying none is the agent talking, which is the closest observable
    // signal to it being finished.
    const stillWorking =
      Array.isArray(event.toolResults) && event.toolResults.length > 0;
    if (stillWorking || !stale || steeredThisEpisode) return;

    steeredThisEpisode = true;
    pi.sendMessage(
      {
        customType: "verify-guard-steer",
        content:
          "[verify-guard] The worktree has changes the verifier has not passed on. Call the `verify` tool " +
          "and report its real output before calling this done. If it cannot run here, say so and say why.",
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
          `verify-guard: ${active ? "active" : "inert (no command configured, or not a git repo)"}`,
          `command: ${cfg.command ?? "(none)"}`,
          `runs in: ${runDir || "(none)"}`,
          `state: ${state()}`,
          `runs this session: ${verifyRuns}`,
        ].join("\n"),
        "info",
      );
    },
  });
}
