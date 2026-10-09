/**
 * stall-guard: keep a long bash command from holding the agent, and question
 * a wait that stops making progress.
 *
 * pi's bash has no default timeout and kills at the one it is given
 * (bash.ts), and a steer lands only after tool calls finish
 * (docs/how-pi-works.md), so a wait that never ends holds the agent where
 * nothing can reach it. In the TUI this re-registers bash from pi's own
 * definition and local operations and changes only when the call returns:
 * a command still running after DETACH_AFTER_MS keeps running as a job and
 * the call returns its output so far. Spawn, environment and sandbox are
 * the built-in's. Other modes keep the built-in behavior, since print and
 * json runs exit when the turn ends and pi-delegate counts turns over RPC.
 * pi builds its own bash with the shellCommandPrefix and shellPath
 * settings; this repo sets neither, so the defaults here match.
 *
 * While jobs run, a heartbeat updates the status line and asks the model
 * about a job that has printed nothing new, on a doubling schedule. A job
 * that ends reports as a steer, which starts a turn when the agent is idle.
 *
 * Repeating results are questioned too: OpenHands' same action, same
 * observation check (software-agent-sdk stuck_detector.py@cd17bd8,
 * L156-L190) over consecutive bash results, at its default of 4, or 2 when
 * the runs timed out (SWE-agent quits after 3: agents.py@3ea751c,
 * L965-L989). Comparison drops the timeout status and pi's temp file path,
 * which differ between otherwise identical runs, and folds digits in the
 * command.
 */

import { createHash } from "node:crypto";
import { createWriteStream, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  type BashOperations,
  type ExtensionAPI,
  type ExtensionContext,
  createBashToolDefinition,
  createLocalBashOperations,
} from "@earendil-works/pi-coding-agent";

const DETACH_AFTER_MS = 120_000;
const HEARTBEAT_MS = 90_000;
// Bytes of a job's latest output kept in memory for the messages quoting it.
const TAIL_BYTES = 4096;
const REPEATS_FINISHED = 4;
const REPEATS_TIMED_OUT = 2;

const TIMED_OUT = /(?:\n\n)?Command timed out after \d+ seconds$/;
const FULL_OUTPUT_PATH = /Full output: [^\]]+\]/g;

const CHECK = [
  "Answer each in one line:",
  "1. What exactly are you waiting for, and which process produces it? Is that process alive?",
  "2. What has changed since you last looked? If nothing, why would the next look be different?",
  "3. Can your exit condition actually match? Test it against a line it should match.",
  "4. What is your deadline, and what will you do when it passes?",
  "Then keep waiting, fix the wait, or stop it.",
].join("\n");

interface Job {
  id: number;
  command: string;
  startedAt: number;
  log: string;
  pidFile: string;
  bytes: number;
  bytesAtBeat: number;
  silentBeats: number;
  tail: string;
  detached: boolean;
  stoppedFromJobs: boolean;
  stop: () => void;
}

function elapsed(ms: number): string {
  const total = Math.round(ms / 1000);
  const minutes = Math.floor(total / 60);
  if (minutes >= 60) return `${Math.floor(minutes / 60)}h${minutes % 60}m`;
  if (minutes > 0) return `${minutes}m${total % 60}s`;
  return `${total}s`;
}

function lastLines(text: string, n: number): string {
  return text.trimEnd().split("\n").slice(-n).join("\n") || "(none)";
}

function shellQuote(s: string): string {
  return `'${s.replaceAll("'", `'\\''`)}'`;
}

function short(command: string): string {
  const line = command.split("\n")[0];
  return line.length > 80 || command.includes("\n")
    ? `${line.slice(0, 80)}...`
    : line;
}

export default function (pi: ExtensionAPI) {
  const jobs = new Map<number, Job>();
  let nextJobId = 1;
  let runs = 0;
  let beat: ReturnType<typeof setInterval> | undefined;
  let ui: ExtensionContext | undefined;
  let shuttingDown = false;
  let last: { key: string; count: number } | undefined;

  const pidOf = (job: Job): string => {
    try {
      return readFileSync(job.pidFile, "utf8").trim() || "?";
    } catch {
      return "?";
    }
  };

  const where = (job: Job): string =>
    `Output goes to ${job.log}; check it with \`tail ${job.log}\`, ` +
    `stop the job with \`kill -- -${pidOf(job)}\`.`;

  const report = (text: string): void =>
    pi.sendMessage(
      { customType: "stall-guard", content: text, display: true },
      { deliverAs: "steer", triggerTurn: true },
    );

  const showStatus = (): void => {
    if (!ui?.hasUI) return;
    const now = Date.now();
    ui.ui.setStatus(
      "stall-guard",
      jobs.size === 0
        ? undefined
        : [...jobs.values()]
            .map(
              (job) =>
                `job ${job.id} ${elapsed(now - job.startedAt)}` +
                (job.silentBeats > 0
                  ? ` silent ${elapsed(job.silentBeats * HEARTBEAT_MS)}`
                  : ""),
            )
            .join(", "),
    );
  };

  const tick = (): void => {
    const now = Date.now();
    for (const job of jobs.values()) {
      job.silentBeats = job.bytes > job.bytesAtBeat ? 0 : job.silentBeats + 1;
      job.bytesAtBeat = job.bytes;
      // Beats 2, 4, 8, ...: first after three minutes of silence, then
      // each gap doubles, so a job that is quiet by design costs a few turns.
      const n = job.silentBeats;
      if (n < 2 || (n & (n - 1)) !== 0) continue;
      report(
        `stall-guard: background job ${job.id} (\`${short(job.command)}\`) ` +
          `has printed nothing new for ${elapsed(n * HEARTBEAT_MS)}, ` +
          `${elapsed(now - job.startedAt)} after it started. Last output:\n` +
          `${lastLines(job.tail, 5)}\n${where(job)}\n${CHECK}`,
      );
    }
    showStatus();
  };

  const track = (job: Job): void => {
    jobs.set(job.id, job);
    beat ??= setInterval(tick, HEARTBEAT_MS);
    showStatus();
  };

  const finish = (job: Job, exitCode: number | null, error?: unknown) => {
    jobs.delete(job.id);
    if (jobs.size === 0 && beat !== undefined) {
      clearInterval(beat);
      beat = undefined;
    }
    showStatus();
    rmSync(job.pidFile, { force: true });
    if (shuttingDown) return;

    const message = error instanceof Error ? error.message : String(error);
    const status = job.stoppedFromJobs
      ? "was stopped from /jobs"
      : error === undefined
        ? exitCode === null
          ? "ended without an exit code"
          : `exited with code ${exitCode}`
        : message.startsWith("timeout:")
          ? `timed out after ${message.slice("timeout:".length)} seconds and was killed`
          : `failed: ${message}`;
    report(
      `Background job ${job.id} (\`${short(job.command)}\`) ${status} after ` +
        `${elapsed(Date.now() - job.startedAt)}. Last output:\n` +
        `${lastLines(job.tail, 20)}\nFull output: ${job.log}`,
    );
  };

  const base = createBashToolDefinition(process.cwd());
  pi.registerTool({
    ...base,
    description:
      `${base.description} In an interactive session, a command still ` +
      `running after ${DETACH_AFTER_MS / 1000} seconds keeps running in the ` +
      `background: the call returns its output so far with a job id, pid ` +
      `and log path, and a message arrives when it exits. A timeout still ` +
      `kills the command when it expires.`,
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      const cwd = ctx?.cwd ?? process.cwd();
      if (ctx?.mode !== "tui") {
        return createBashToolDefinition(cwd).execute(
          toolCallId,
          params,
          signal,
          onUpdate,
          ctx,
        );
      }
      ui = ctx;

      for (const job of jobs.values()) {
        if (job.command !== params.command) continue;
        return {
          content: [
            {
              type: "text",
              text:
                `The same command is already running as background job ` +
                `${job.id}, started ${elapsed(Date.now() - job.startedAt)} ` +
                `ago, so it was not started again. Last output:\n` +
                `${lastLines(job.tail, 5)}\n${where(job)}`,
            },
          ],
          details: undefined,
        };
      }

      let detached: Job | undefined;
      const local = createLocalBashOperations();
      const operations: BashOperations = {
        exec: (command, execCwd, options) =>
          new Promise((resolve, reject) => {
            const log = join(tmpdir(), `pi-job-${process.pid}-${++runs}.log`);
            // An unhandled stream error would take pi down; losing the log
            // only costs the full output, and the tail is kept in memory.
            const out = createWriteStream(log).on("error", () => {});
            const abort = new AbortController();
            const forwardAbort = (): void => abort.abort();
            options.signal?.addEventListener("abort", forwardAbort, {
              once: true,
            });
            const job: Job = {
              id: 0,
              command: params.command,
              startedAt: Date.now(),
              log,
              pidFile: `${log}.pid`,
              bytes: 0,
              bytesAtBeat: 0,
              silentBeats: 0,
              tail: "",
              detached: false,
              stoppedFromJobs: false,
              stop: forwardAbort,
            };

            // `$$` is the shell, which pi spawns detached, so it leads the
            // process group that `kill -- -<pid>` ends. Same line as the
            // command so bash's error line numbers stay the model's.
            const run = local.exec(
              `printf '%s' "$$" > ${shellQuote(job.pidFile)}; ${command}`,
              execCwd,
              {
                ...options,
                signal: abort.signal,
                onData: (data) => {
                  out.write(data);
                  job.bytes += data.length;
                  job.tail = (job.tail + data.toString()).slice(-TAIL_BYTES);
                  if (!job.detached) options.onData(data);
                },
              },
            );

            const timer = setTimeout(() => {
              options.signal?.removeEventListener("abort", forwardAbort);
              job.detached = true;
              job.id = nextJobId++;
              job.bytesAtBeat = job.bytes;
              detached = job;
              track(job);
              resolve({ exitCode: 0 });
            }, DETACH_AFTER_MS);

            const settle = (): void => {
              clearTimeout(timer);
              options.signal?.removeEventListener("abort", forwardAbort);
              out.end();
              if (job.detached) return;
              rmSync(log, { force: true });
              rmSync(job.pidFile, { force: true });
            };
            run.then(
              (result) => {
                settle();
                if (job.detached) finish(job, result.exitCode);
                else resolve(result);
              },
              (error) => {
                settle();
                if (job.detached) finish(job, null, error);
                else reject(error);
              },
            );
          }),
      };

      const result = await createBashToolDefinition(cwd, {
        operations,
      }).execute(toolCallId, params, signal, onUpdate, ctx);
      if (detached === undefined) return result;
      return {
        ...result,
        content: [
          ...result.content,
          {
            type: "text",
            text:
              `Still running after ${DETACH_AFTER_MS / 1000}s, so it moved ` +
              `to the background as job ${detached.id} ` +
              `(pid ${pidOf(detached)}). ${where(detached)} A message ` +
              `arrives when it exits.`,
          },
        ],
        // The built-in reports the exit code 0 that ended the foreground
        // wait, which the still-running job never returned.
        structuredContent: undefined,
      };
    },
  });

  pi.registerCommand("jobs", {
    description: "List background bash jobs; `/jobs kill <id>` stops one",
    handler: async (args, ctx) => {
      const [verb, id] = args.trim().split(/\s+/);
      if (verb === "kill") {
        const job = jobs.get(Number(id));
        if (job === undefined) {
          ctx.ui.notify(`stall-guard: no background job ${id}`, "warning");
          return;
        }
        job.stoppedFromJobs = true;
        job.stop();
        return;
      }
      const now = Date.now();
      ctx.ui.notify(
        jobs.size === 0
          ? "stall-guard: no background jobs"
          : [...jobs.values()]
              .map(
                (job) =>
                  `job ${job.id}, pid ${pidOf(job)}, ` +
                  `${elapsed(now - job.startedAt)}: ${short(job.command)}`,
              )
              .join("\n"),
        "info",
      );
    },
  });

  pi.on("session_start", (_event, ctx) => {
    ui = ctx;
  });

  // pi can exit before a stopped job's exit reaches finish(), so the pid
  // files go here. Logs stay for later reading.
  pi.on("session_shutdown", () => {
    shuttingDown = true;
    if (beat !== undefined) clearInterval(beat);
    for (const job of jobs.values()) {
      job.stop();
      rmSync(job.pidFile, { force: true });
    }
  });

  pi.on("tool_result", (event, ctx) => {
    if (event.toolName !== "bash") return;

    const text = event.content
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("\n");
    const timedOut = event.isError && TIMED_OUT.test(text);
    const output = text
      .replace(TIMED_OUT, "")
      .replace(FULL_OUTPUT_PATH, "Full output]");
    const command = String(event.input.command ?? "")
      .replace(/\d+/g, "N")
      .replace(/\s+/g, " ")
      .trim();
    const key = createHash("sha256")
      .update(`${timedOut}\0${command}\0${output}`)
      .digest("hex");
    last =
      last?.key === key ? { key, count: last.count + 1 } : { key, count: 1 };

    const threshold = timedOut ? REPEATS_TIMED_OUT : REPEATS_FINISHED;
    if (last.count < threshold) return;
    if (ctx.hasUI) {
      ctx.ui.notify(
        last.count === threshold
          ? `stall-guard: ${last.count} identical runs of a bash command`
          : `stall-guard: the agent re-ran a bash command after being asked ` +
              `to check it (${last.count} identical runs)`,
        "warning",
      );
    }
    return {
      content: [
        ...event.content,
        {
          type: "text",
          text:
            `stall-guard: this command has ${timedOut ? "timed out" : "ended"} ` +
            `${last.count} times in a row with the same output. Before ` +
            `running it again:\n${CHECK}`,
        },
      ],
      structuredContent: event.structuredContent,
    };
  });
}
