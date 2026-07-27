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
 * Off unless --domestique is passed.
 */

import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const ROOT = join(homedir(), ".pi", "domestique");
const SPOOL = join(ROOT, "spool");
const STOP = join(ROOT, "stop");
const STOP_THINK = join(ROOT, "stop-think");
const SPEED_FILE = join(ROOT, "speed");

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
 */
function speakable(text: string): string {
  return text
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/https?:\/\/\S+/g, "a link")
    .replace(/^\s{0,3}#{1,6}\s+/gm, "")
    .replace(/^\s*[-*+]\s+/gm, "")
    .replace(/^\s*\d+[.)]\s+/gm, "")
    .replace(/[*_`\[\]]+/g, "")
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
    // utterance and it never reads a half-written file.
    writeFileSync(tmp, `${body}\n`, "utf8");
    renameSync(tmp, join(SPOOL, `${name}.txt`));
    uttered += 1;
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
    inFence = false;
    writeFileSync(STOP, "", "utf8");
  }

  /**
   * Deliver whatever the rider has said, oldest first. Each file is unlinked
   * before its send, so a throw costs one utterance instead of repeating it
   * on every tick.
   */
  function drainHeard(ctx: {
    ui?: { notify: (m: string, l: string) => void };
  }) {
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
      let text: string;
      try {
        text = readFileSync(path, "utf8").trim();
      } catch {
        continue;
      }
      rmSync(path, { force: true });
      if (!text) continue;

      heard += 1;
      ctx.ui?.notify(`heard: ${text}`, "info");
      // Streaming without deliverAs throws; idle with it never starts a turn.
      pi.sendUserMessage(text, turnActive ? { deliverAs: "steer" } : undefined);
    }
  }

  /** Drop the thinking ticker, but let a queued response finish speaking. */
  function quietThinking(): void {
    buffers.think = "";
    writeFileSync(STOP_THINK, "", "utf8");
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

    if (ctx.hasUI) {
      ctx.ui.setStatus("domestique", ctx.ui.theme.fg("accent", "domestique"));
    }

    let shown = false;
    heardTimer = setInterval(() => {
      drainHeard(ctx);
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
