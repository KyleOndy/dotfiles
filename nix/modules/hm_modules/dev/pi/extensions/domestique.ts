/**
 * domestique: speak pi's stream aloud for trainer rides.
 *
 * This extension makes no sound itself. Inside pi's strict sandbox the CoreAudio
 * mach lookup is denied, and srt's settings schema (nix/pkgs/pi-wrapper/
 * wrapper.sh) exposes no mach knob to reopen it, so playback has to happen
 * outside. Each utterance lands in a spool file under ~/.pi, which strict mode
 * keeps writable, and the unsandboxed watcher owns the audio device.
 *
 * Two channels with opposite loss policies:
 *   think  Lossy, newest-wins. Thinking runs several hundred words per turn
 *          against roughly 150 wpm of speech, so a lossless queue is minutes
 *          behind by the third turn.
 *   speak  Lossless FIFO. Preempts think.
 *
 * The drop policy lives in the watcher; this side only decides what counts as
 * one utterance.
 *
 * "new topic" restarts pi through the wrapper rather than clearing the session
 * in place: newSession() is reachable only from a slash-command context, and
 * discarding a finished topic costs a restart where compacting it costs a
 * summarization.
 *
 * Off unless --domestique is passed.
 */

import { spawn } from "node:child_process";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";

import { Type } from "typebox";

import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

const ROOT = join(homedir(), ".pi", "domestique");
const SPOOL = join(ROOT, "spool");
const STOP = join(ROOT, "stop");
const STOP_THINK = join(ROOT, "stop-think");
const SPEED_FILE = join(ROOT, "speed");

// Read by the wrapper's relaunch loop, and by the next session for the topic
// it should open on. TOPIC is absent for the first session of a ride.
const RESTART = join(ROOT, "restart");
const TOPIC = join(ROOT, "topic");

// Repository git directories for clone_repo, outside the ride directory because
// srt denies writes to any path ending .git/config.
const GITDIRS = join(ROOT, "gitdirs");

// Paths srt refuses to write inside the ride directory, so a clone has to leave
// them out of the checkout. Verified against a strict-mode sandbox rather than
// read off the wrapper: .git/config, .git/hooks and .gitmodules come from
// nix/pkgs/pi-wrapper/wrapper.sh, the rest are srt's own and are matched by
// subtree, not by exact name.
const DENIED_PATHS = [".claude/", ".vscode/", ".mcp.json", ".gitmodules"];

// What the rider said, transcribed by domestique-listen.py. Speech goes out
// through the spool and comes back in through here, so the microphone half
// needs no keystroke synthesis and no accessibility grant.
const HEARD = join(ROOT, "heard");
const HEARD_POLL_MS = 200;

// Karabiner holds this open while the push-to-talk key is down. The watcher
// rings for it; this is the same thing for anyone at a desk.
const LISTENING = join(ROOT, "listening");

// The watcher clamps to the same range; these bounds are here so /speed reports
// the rate it actually set.
const SPEED_MIN = 0.5;
const SPEED_MAX = 2.0;
const SPEED_STEP = 0.1;

// Below this, an utterance is not worth its own synthesis call and its own
// bluetooth wake-up, so the buffer keeps accumulating past the boundary.
const MIN_UTTERANCE_CHARS = 16;
// Thinking often runs long stretches with no sentence punctuation at all, so
// there has to be a length at which we flush anyway.
const MAX_UTTERANCE_CHARS = 320;
// Roughly six sentences, or a minute of speech, per assistant message. The
// ride system prompt asks for two to four, so hitting this means the prompt
// is not holding.
const RESPONSE_CHAR_BUDGET = 900;

// Announced once per session, and only while idle so it cannot land inside an
// answer. Early enough that the rider picks the break rather than pi picking
// it at the compaction threshold.
const CONTEXT_WARN_PERCENT = 70;

// Leading "new topic" or a synonym, with whatever separator the recognizer
// supplied. The remainder is the topic and opens the next session.
//
// Anchored, so "the next topic is alerting" mid-utterance is not a command.
// "start over" and "reset" are deliberately absent: both are ordinary things to
// say about the work, and a session discarded by accident does not come back.
const TOPIC_RE =
  /^\s*(?:new|next) (?:topic|session|chat|conversation)[\s,.:;-]*/i;

// Matched against the whole normalized utterance, never a prefix: "should we
// compact this" is a question about compaction, not a request for one.
const COMPACT_PHRASES = new Set(["compact", "compact context"]);

// Words that end in a period without ending a sentence. Deliberately short:
// a missed boundary only means one longer utterance, while a wrong boundary
// speaks a fragment.
const ABBREVIATIONS = new Set([
  "e.g",
  "i.e",
  "etc",
  "vs",
  "cf",
  "approx",
  "fig",
  "al",
  "dr",
  "mr",
  "mrs",
  "ms",
]);

type Channel = "think" | "speak";

/** True when the period at `dotIndex` belongs to an abbreviation or initial. */
function isAbbreviation(buf: string, dotIndex: number): boolean {
  let start = dotIndex;
  while (start > 0 && /[A-Za-z.]/.test(buf[start - 1])) start--;
  const word = buf.slice(start, dotIndex).toLowerCase();
  // Markdown is stripped per-utterance, after splitting, so a sentence here
  // can still end in a backtick, digit, or bracket. Those leave no preceding
  // word and are ordinary sentence ends, not initials.
  if (!word) return false;
  return word.length === 1 || ABBREVIATIONS.has(word);
}

/** Index just past the first usable sentence boundary, or -1 if there is none. */
function sentenceEnd(buf: string): number {
  for (let i = 0; i < buf.length; i++) {
    const c = buf[i];
    if (c === "\n" && buf[i + 1] === "\n" && i + 2 >= MIN_UTTERANCE_CHARS) {
      return i + 2;
    }
    if (c !== "." && c !== "!" && c !== "?") continue;
    let j = i + 1;
    while (j < buf.length && "\"')]".includes(buf[j])) j++;
    // Still mid-token; a later delta decides whether this is a boundary.
    if (j >= buf.length) return -1;
    // Rejects decimals and dotted identifiers: 0.82.1, foo.bar, tiger.infra.
    if (!/\s/.test(buf[j])) continue;
    if (c === "." && isAbbreviation(buf, i)) continue;
    if (j < MIN_UTTERANCE_CHARS) continue;
    return j;
  }
  return -1;
}

/** Cut point when no sentence boundary arrived before MAX_UTTERANCE_CHARS. */
function hardCut(buf: string): number {
  const space = buf.slice(0, MAX_UTTERANCE_CHARS).lastIndexOf(" ");
  return space > MIN_UTTERANCE_CHARS ? space + 1 : MAX_UTTERANCE_CHARS;
}

/**
 * Strip what does not survive being read aloud. Square brackets included:
 * misaki reads `[word](/phonemes/)` as a pronunciation override, so
 * "see [docs](/api/v1/)" phonemizes to `sˈi api/v1`.
 *
 * Backticks and underscores pass through: domestique-tts.py speakable() reads
 * identifier word boundaries from them.
 */
function speakable(text: string): string {
  return text
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/https?:\/\/\S+/g, "a link")
    .replace(/^\s{0,3}#{1,6}\s+/gm, "")
    .replace(/^\s*[-*+]\s+/gm, "")
    .replace(/^\s*\d+[.)]\s+/gm, "")
    .replace(/[*\[\]]+/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

export default function (pi: ExtensionAPI) {
  pi.registerFlag("domestique", {
    description: "Speak thinking and responses aloud via the domestique spool",
    type: "boolean",
    default: false,
  });

  let enabled = false;
  let seq = 0;
  const buffers: Record<Channel, string> = { think: "", speak: "" };

  let spokenChars = 0;
  let responseMuted = false;
  let truncated = 0;
  let codeSuppressed = 0;
  let codeAnnounced = false;
  let uttered = 0;
  let heard = 0;

  let transcript = "";
  let rideDir = "";
  // Spoken prose of the message in flight. Flushed whole so one answer is one
  // transcript line rather than one line per sentence.
  let said = "";
  let contextWarned = false;

  // A turn is in flight, so a transcript has to say how it wants to be
  // delivered rather than starting a second one.
  let turnActive = false;
  let heardTimer: ReturnType<typeof setInterval> | undefined;

  // Response text not yet classified as prose or code, and which of the two we
  // are in. Held outside the speech buffer because a fence marker arrives split
  // across deltas as often as not.
  let pending = "";
  let inFence = false;

  function writeUtterance(channel: Channel, body: string): void {
    seq += 1;
    const name = `${String(seq).padStart(6, "0")}-${channel}`;
    const tmp = join(SPOOL, `${name}.tmp`);
    // The watcher globs *.txt only, so the rename is what publishes the
    // utterance and it never reads a half-written file. It also sweeps the
    // spool at its own startup, which can take the temporary file out from
    // between these two calls; one utterance is the right cost for that, where
    // a throw would take the whole stream handler.
    try {
      writeFileSync(tmp, `${body}\n`, "utf8");
      renameSync(tmp, join(SPOOL, `${name}.txt`));
    } catch {
      return;
    }
    uttered += 1;
  }

  function logLine(line: string): void {
    if (!transcript) return;
    try {
      appendFileSync(transcript, `${line}\n`, "utf8");
    } catch {
      // A ride does not end because its notes failed.
    }
  }

  /** Hand text to drainHeard as though the rider had said it. Named as
   * domestique-listen.py publish() names its files, so ordering holds. The
   * replay suffix marks text this extension wrote rather than heard, which is
   * not eligible to be read as a command: a topic of "new session handling"
   * would otherwise end the session opened to discuss it. */
  function publishHeard(text: string, replayed = false): void {
    const name = String(Date.now()).padStart(13, "0");
    const tmp = join(HEARD, `${name}.tmp`);
    writeFileSync(tmp, `${text}\n`, "utf8");
    renameSync(tmp, join(HEARD, `${name}${replayed ? ".replay" : ""}.txt`));
  }

  /** Take up the topic the previous session was ended for. Absent on the
   * first session of a ride. */
  function openTopic(): void {
    let topic = "";
    try {
      topic = readFileSync(TOPIC, "utf8").trim();
    } catch {
      // First session of the ride.
    }
    rmSync(TOPIC, { force: true });

    const at = new Date().toTimeString().slice(0, 5);
    logLine(`\n## ${at} ${topic || "ride start"}`);
    if (!topic) return;
    pi.setSessionName(topic);
    publishHeard(topic, true);
  }

  /** Stop the response channel for this message and say why instead. */
  function mute(marker: string): void {
    buffers.speak = "";
    writeUtterance("speak", marker);
    responseMuted = true;
  }

  function spool(channel: Channel, text: string): void {
    const body = speakable(text);
    if (!body) return;
    if (channel === "speak" && responseMuted) return;
    writeUtterance(channel, body);
    if (channel !== "speak") return;
    said = said ? `${said} ${body}` : body;
    spokenChars += body.length;
    if (spokenChars >= RESPONSE_CHAR_BUDGET) {
      truncated += 1;
      mute("Rest is on screen.");
    }
  }

  function feed(channel: Channel, delta: string): void {
    buffers[channel] += delta;
    for (;;) {
      let cut = sentenceEnd(buffers[channel]);
      if (cut < 0) {
        if (buffers[channel].length < MAX_UTTERANCE_CHARS) return;
        cut = hardCut(buffers[channel]);
      }
      spool(channel, buffers[channel].slice(0, cut));
      buffers[channel] = buffers[channel].slice(cut);
      if (channel === "speak" && responseMuted) return;
    }
  }

  function drain(channel: Channel): void {
    const rest = buffers[channel];
    buffers[channel] = "";
    if (rest.trim()) spool(channel, rest);
  }

  /** The rate the watcher will use next, which it publishes at startup. */
  function storedSpeed(): number {
    try {
      const stored = Number.parseFloat(readFileSync(SPEED_FILE, "utf8"));
      if (Number.isFinite(stored)) return stored;
    } catch {
      // No file means no watcher yet, and its startup write wins anyway.
    }
    return 1;
  }

  /** Rounded to two places, so stepping by 0.1 does not accumulate drift. */
  function clampSpeed(rate: number): number {
    const bounded = Math.min(SPEED_MAX, Math.max(SPEED_MIN, rate));
    return Math.round(bounded * 100) / 100;
  }

  /** Backticks at the end of the text, short of a full fence marker. */
  function trailingBackticks(text: string): number {
    let n = 0;
    while (n < 2 && text[text.length - 1 - n] === "`") n++;
    return n;
  }

  /** Point the rider at the screen, once per message however many blocks. */
  function announceCode(): void {
    codeSuppressed += 1;
    if (codeAnnounced) return;
    codeAnnounced = true;
    writeUtterance("speak", "Code on screen.");
  }

  /**
   * Speak the prose of a response and skip the fenced blocks.
   *
   * A fence suspends speech rather than ending it. The explanation after a code
   * block is usually the half of the answer worth hearing, and on a bike it is
   * also the half that cannot be read.
   */
  function feedResponse(delta: string): void {
    if (responseMuted) return;
    pending += delta;
    for (;;) {
      const fence = pending.indexOf("```");
      if (inFence) {
        if (fence < 0) {
          pending = "`".repeat(trailingBackticks(pending));
          return;
        }
        pending = pending.slice(fence + 3);
        inFence = false;
        continue;
      }
      if (fence < 0) {
        const held = trailingBackticks(pending);
        feed("speak", pending.slice(0, pending.length - held));
        pending = pending.slice(pending.length - held);
        return;
      }
      feed("speak", pending.slice(0, fence));
      pending = pending.slice(fence + 3);
      inFence = true;
      // The sentence introducing a block ("here is the unit file:") is still in
      // the buffer, and waiting for a boundary that the code swallowed would
      // speak it after the block or not at all.
      drain("speak");
      announceCode();
    }
  }

  function hush(): void {
    buffers.think = "";
    buffers.speak = "";
    pending = "";
    // inFence is not ours to clear. It tracks where the model is in the text it
    // is still streaming, so clearing it here reads the rest of a code block as
    // prose and speaks it, then takes the real closing fence as an opening one
    // and swallows the paragraph that explains the block. message_start is
    // where it belongs, being the only point the stream actually restarts.
    writeFileSync(STOP, "", "utf8");
  }

  function normalize(text: string): string {
    return text
      .toLowerCase()
      .replace(/[^a-z ]/g, "")
      .replace(/\s+/g, " ")
      .trim();
  }

  /**
   * End the session, leaving the topic for the next one. The wrapper relaunches
   * pi, so the watchers, the spool numbering and the ride directory all survive
   * while the context starts empty.
   */
  function newTopic(ctx: ExtensionContext, topic: string): void {
    if (topic) writeFileSync(TOPIC, `${topic}\n`, "utf8");
    else rmSync(TOPIC, { force: true });
    writeFileSync(RESTART, "", "utf8");
    writeUtterance("speak", "New topic.");
    ctx.abort();
    ctx.shutdown();
  }

  function compactNow(ctx: ExtensionContext): void {
    if (!ctx.isIdle()) ctx.abort();
    ctx.compact({
      onError: (error) =>
        writeUtterance("speak", `Compaction failed. ${error.message}`),
    });
  }

  function warnContext(ctx: ExtensionContext): void {
    if (contextWarned || !ctx.isIdle()) return;
    const percent = ctx.getContextUsage()?.percent;
    if (percent === null || percent === undefined) return;
    if (percent < CONTEXT_WARN_PERCENT) return;
    contextWarned = true;
    writeUtterance("speak", "Context is filling up. Say new topic at a break.");
  }

  /**
   * Deliver whatever the rider has said, oldest first. Each file is unlinked
   * before its send, so a throw costs one utterance instead of repeating it
   * on every tick.
   */
  function drainHeard(ctx: ExtensionContext) {
    let names: string[];
    try {
      names = readdirSync(HEARD)
        .filter((n) => n.endsWith(".txt"))
        .sort();
    } catch {
      // The listener owns this directory.
      return;
    }

    for (const name of names) {
      const path = join(HEARD, name);
      const replayed = name.endsWith(".replay.txt");
      let text: string;
      try {
        text = readFileSync(path, "utf8").trim();
      } catch {
        continue;
      }
      rmSync(path, { force: true });
      if (!text) continue;

      heard += 1;
      logLine(`> ${text}`);
      ctx.ui?.notify(`heard: ${text}`, "info");

      // The key going down already hushed the watcher and cleared the spool
      // (domestique-tts.py, LISTENING edge), so an acknowledgement spooled here
      // cannot be caught by a stop file still in flight.
      if (!replayed && TOPIC_RE.test(text)) {
        newTopic(ctx, text.replace(TOPIC_RE, "").trim());
        return;
      }
      if (!replayed && COMPACT_PHRASES.has(normalize(text))) {
        compactNow(ctx);
        continue;
      }

      // Streaming without deliverAs throws; idle with it never starts a turn.
      pi.sendUserMessage(text, turnActive ? { deliverAs: "steer" } : undefined);
      // The turn is live from here, while message_start is a round trip away.
      // An utterance arriving in that gap goes bare into a streaming session,
      // throws asynchronously, and is gone with its file already unlinked.
      turnActive = true;
    }
  }

  /** Drop the thinking ticker, but let a queued response finish speaking. */
  function quietThinking(): void {
    buffers.think = "";
    writeFileSync(STOP_THINK, "", "utf8");
  }

  function run(
    command: string,
    args: string[],
    signal?: AbortSignal,
  ): Promise<void> {
    return new Promise((resolve, reject) => {
      const child = spawn(command, args, {
        stdio: ["ignore", "ignore", "pipe"],
      });
      let stderr = "";
      child.stderr?.on("data", (chunk: unknown) => {
        stderr += String(chunk);
      });
      const abort = (): void => {
        child.kill("SIGTERM");
      };
      signal?.addEventListener("abort", abort, { once: true });
      child.on("error", reject);
      child.on("close", (code) => {
        signal?.removeEventListener("abort", abort);
        if (code === 0) resolve();
        else reject(new Error(stderr.trim() || `${command} exited ${code}`));
      });
    });
  }

  /** Repo name to path, from the paths the wrapper exports (domestique.nix). */
  function configuredRepos(): Map<string, string> {
    const repos = new Map<string, string>();
    for (const line of (process.env.DOMESTIQUE_REPOS ?? "").split("\n")) {
      const path = line.trim();
      if (!path) continue;
      // Two configured repos can share a last component, a work `infra` and a
      // homelab one. Keyed on that alone the later would replace the earlier
      // and clone the wrong codebase under the right name, with nothing said.
      const name = basename(path);
      repos.set(
        repos.has(name) ? join(basename(dirname(path)), name) : name,
        path,
      );
    }
    return repos;
  }

  /** A writable copy of one repo inside the ride directory.
   *
   * A tool rather than a documented recipe because the flag carries the cost:
   * --shared points the clone's alternates at the original object store, and
   * without it git copies 1.9G for the largest of these. The agent cannot be
   * relied on to remember that mid-ride, and nobody is watching the screen.
   *
   * Registered per ride, so an ordinary pi session never sees it. */
  function registerClone(): void {
    const repos = configuredRepos();
    if (repos.size === 0) return;
    const names = [...repos.keys()].sort();
    const available = names.join(", ");

    pi.registerTool({
      name: "clone_repo",
      label: "Clone repo",
      description:
        "Make a writable clone of one of the rider's repositories inside the " +
        `ride directory. Available: ${available}.`,
      promptSnippet: `Clone a work repo into the ride directory (${available})`,
      promptGuidelines: [
        "Use clone_repo before editing, committing or testing anything in a work repository. The originals are read-only, and the ride directory is the only writable place.",
        "clone_repo cannot push and neither can anything else here. Commit locally and name the branch out loud; the rider picks it up after the ride.",
      ],
      parameters: Type.Object({
        name: Type.String({ description: `One of: ${available}.` }),
      }),
      async execute(_toolCallId, params, signal, onUpdate) {
        const source = repos.get(params.name);
        if (!source) {
          throw new Error(
            `No repo named "${params.name}". Available: ${available}.`,
          );
        }
        if (!rideDir) throw new Error("No ride directory to clone into.");

        const dest = join(rideDir, "repos", params.name);
        if (existsSync(dest)) {
          return {
            content: [
              { type: "text", text: `Already cloned at repos/${params.name}.` },
            ],
          };
        }

        // The worktrees carry a .git file pointing at a sibling .bare, matching
        // what domestique-fetch freshens.
        const source_gitdir = existsSync(join(source, ".bare"))
          ? join(source, ".bare")
          : source;

        // Keyed by ride so domestique's start-of-ride prune can drop a git
        // directory together with the worktree it belongs to.
        const gitdir = join(GITDIRS, basename(rideDir), params.name);
        mkdirSync(join(GITDIRS, basename(rideDir)), { recursive: true });

        // Hundreds of megabytes of checkout is dead air otherwise, and dead air
        // reads as a crash to someone who cannot see the screen.
        writeUtterance("speak", `Cloning ${params.name}, one moment.`);
        onUpdate?.({
          content: [{ type: "text", text: `cloning ${params.name}` }],
        });

        try {
          // Three steps rather than a plain clone, both forced by what srt
          // refuses to write in the ride directory. --separate-git-dir keeps
          // `config` out of any path ending .git/config, denied at any depth.
          // The exclusions keep the checkout off DENIED_PATHS, where the first
          // one reached aborts it with the tree half populated; skipped instead,
          // `git status` stays clean. Every repo here carries at least one.
          await run(
            "git",
            [
              "clone",
              "--no-checkout",
              "--shared",
              `--separate-git-dir=${gitdir}`,
              source_gitdir,
              dest,
            ],
            signal,
          );
          await run(
            "git",
            [
              "-C",
              dest,
              "sparse-checkout",
              "set",
              "--no-cone",
              "/*",
              ...DENIED_PATHS.map((path) => `!${path}`),
            ],
            signal,
          );
          await run("git", ["-C", dest, "checkout"], signal);
          // .bare keeps most branches as remote-tracking refs and a clone
          // fetches refs/heads only, which leaves the branch the rider names
          // absent more often than not: 72 refs of 496 for the busiest repo.
          // The objects are already shared, so this copies refs and little else.
          await run(
            "git",
            [
              "-C",
              dest,
              "fetch",
              "--quiet",
              "origin",
              "+refs/remotes/origin/*:refs/remotes/origin/*",
            ],
            signal,
          );
        } catch (error) {
          // The existsSync guard above reads a half-populated dest as a
          // finished clone, and the start-of-ride prune skips the ride in
          // progress, so leaving one behind means "already cloned" and an
          // empty tree for the rest of the day.
          rmSync(dest, { recursive: true, force: true });
          rmSync(gitdir, { recursive: true, force: true });
          writeUtterance("speak", `Cloning ${params.name} failed.`);
          throw error;
        }

        writeUtterance("speak", `${params.name} ready.`);
        logLine(`_cloned ${params.name}_`);
        return {
          content: [
            {
              type: "text",
              text:
                `Cloned ${params.name} to repos/${params.name}, on its default ` +
                "branch. Branch, switch, edit and commit freely; every branch " +
                "is fetched. Pushing is not possible, so leave work on a " +
                "local branch and say its name.",
            },
          ],
        };
      },
    });
  }

  pi.on("session_start", (_event, ctx) => {
    enabled = pi.getFlag("domestique") === true;
    if (!enabled) return;

    mkdirSync(SPOOL, { recursive: true });
    mkdirSync(HEARD, { recursive: true });
    // A restart mid-ride would otherwise reuse numbers the watcher has not
    // drained yet, and the new utterances would sort behind the stale ones.
    for (const name of readdirSync(SPOOL)) {
      const n = Number.parseInt(name.slice(0, 6), 10);
      if (Number.isFinite(n) && n > seq) seq = n;
    }

    // The ride directory is pi's $PWD and the only place outside ~/.pi the
    // sandbox lets this write (nix/pkgs/pi-wrapper/wrapper.sh, write_paths).
    rideDir = ctx.cwd;
    transcript = join(ctx.cwd, "transcript.md");
    registerClone();
    openTopic();

    if (ctx.hasUI) {
      ctx.ui.setStatus("domestique", ctx.ui.theme.fg("accent", "domestique"));
    }

    let shown = false;
    heardTimer = setInterval(() => {
      drainHeard(ctx);
      warnContext(ctx);
      const open = existsSync(LISTENING);
      if (open === shown || !ctx.hasUI) return;
      shown = open;
      ctx.ui.setStatus(
        "domestique",
        open
          ? ctx.ui.theme.fg("success", "listening")
          : ctx.ui.theme.fg("accent", "domestique"),
      );
    }, HEARD_POLL_MS);
    // A held timer would keep pi alive after the session ends.
    heardTimer.unref?.();
  });

  pi.on("turn_end", () => {
    turnActive = false;
  });

  // Fires for pi's own threshold compaction as well as for a spoken one, and
  // that is the case worth covering: it is silent, it runs for a while, and a
  // rider who cannot see the screen has no way to tell it from a crash.
  pi.on("session_before_compact", () => {
    if (!enabled) return;
    writeUtterance("speak", "Compacting, one moment.");
    logLine("_compacted here_");
  });

  pi.on("session_compact", () => {
    if (enabled) writeUtterance("speak", "Back.");
  });

  pi.on("message_start", (event, _ctx) => {
    if (!enabled) return;
    const message = event.message as { role?: string } | undefined;
    if (message?.role !== "assistant") return;
    turnActive = true;
    // The budget bounds one spoken chunk, not one exchange. A tool-heavy turn
    // produces several assistant messages and each gets its own allowance.
    spokenChars = 0;
    responseMuted = false;
    codeAnnounced = false;
    pending = "";
    inFence = false;
    said = "";
  });

  pi.on("message_update", (event, _ctx) => {
    if (!enabled) return;
    const delta = (event as { assistantMessageEvent?: unknown })
      .assistantMessageEvent as { type?: string; delta?: string } | undefined;
    if (!delta?.type) return;

    switch (delta.type) {
      case "thinking_delta":
        if (typeof delta.delta === "string") feed("think", delta.delta);
        return;
      case "thinking_end":
        drain("think");
        return;
      case "text_delta":
        if (typeof delta.delta === "string") feedResponse(delta.delta);
        return;
      case "text_end":
        // An unterminated fence means the message ended inside a block, so
        // whatever is held back is code and stays unspoken.
        if (!inFence) feed("speak", pending);
        pending = "";
        drain("speak");
        if (said) {
          logLine(said);
          said = "";
        }
        return;
      case "error":
        hush();
        return;
      default:
        return;
    }
  });

  pi.registerCommand("hush", {
    description: "Stop speaking immediately and drop everything queued",
    handler: (_args, ctx) => {
      if (!enabled) {
        ctx.ui.notify("domestique: not active (pass --domestique)", "info");
        return;
      }
      hush();
      ctx.ui.notify("domestique: hushed", "info");
    },
  });

  pi.registerCommand("speed", {
    description: "Speech rate: a multiplier, or + and - to step it by 0.1",
    handler: (args, ctx) => {
      if (!enabled) {
        ctx.ui.notify("domestique: not active (pass --domestique)", "info");
        return;
      }

      const current = storedSpeed();
      const arg = args.trim();
      let wanted = current;
      if (arg === "+" || arg === "-") {
        wanted = current + (arg === "+" ? SPEED_STEP : -SPEED_STEP);
      } else if (arg) {
        wanted = Number.parseFloat(arg);
        if (!Number.isFinite(wanted)) {
          ctx.ui.notify(
            `domestique: /speed wants a number, got ${arg}`,
            "warning",
          );
          return;
        }
      }

      const speed = clampSpeed(wanted);
      writeFileSync(SPEED_FILE, `${speed}\n`, "utf8");
      ctx.ui.notify(
        `domestique: ${speed.toFixed(2)}x from the next sentence`,
        "info",
      );
    },
  });

  pi.registerCommand("domestique", {
    description: "Show domestique speech-spool counters",
    handler: (_args, ctx) => {
      if (!enabled) {
        ctx.ui.notify("domestique: disabled (pass --domestique)", "info");
        return;
      }
      let queued = 0;
      try {
        queued = readdirSync(SPOOL).filter((n) => n.endsWith(".txt")).length;
      } catch {
        // The watcher owns this directory; if it is gone, so is the audio.
      }
      ctx.ui.notify(
        [
          `domestique: active, spool ${SPOOL}`,
          `transcript: ${transcript}`,
          `context: ${ctx.getContextUsage()?.percent?.toFixed(0) ?? "?"}%`,
          `utterances written: ${uttered}, pending: ${queued}`,
          `transcripts heard: ${heard}`,
          `speech rate: ${storedSpeed().toFixed(2)}x`,
          `responses truncated at ${RESPONSE_CHAR_BUDGET} chars: ${truncated}`,
          `code blocks skipped: ${codeSuppressed}`,
        ].join("\n"),
        "info",
      );
    },
  });

  // The watcher outlives pi, so an exit has to silence the ticker itself.
  // The response still drains: in --print mode pi is gone before the answer
  // has finished speaking.
  pi.on("session_shutdown", () => {
    if (heardTimer) clearInterval(heardTimer);
    if (enabled) quietThinking();
  });
}
