/**
 * domestique: speak pi's stream aloud for trainer rides.
 *
 * This extension never calls `say`. Inside pi's strict sandbox `say` exits 0
 * and produces no audio: synthesis runs (`say -o file.aiff` writes a valid
 * AIFF) but the CoreAudio mach lookup is denied, and srt's settings schema
 * (nix/pkgs/pi-wrapper/wrapper.sh) exposes no mach knob to reopen it. So each
 * utterance lands in a spool file under ~/.pi, which strict mode keeps
 * writable, and the unsandboxed `domestique-speak` owns every call to `say`.
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

import { mkdirSync, readdirSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const ROOT = join(homedir(), ".pi", "domestique");
const SPOOL = join(ROOT, "spool");
const STOP = join(ROOT, "stop");
const STOP_THINK = join(ROOT, "stop-think");

// Below this, an utterance is not worth its own `say` invocation and its own
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
 * Strip what does not survive being read aloud.
 *
 * `say` parses [[...]] as Speech Synthesis Manager commands, so model text
 * containing [[volm 0]] or [[slnc 30000]] would otherwise be executed rather
 * than spoken.
 */
function speakable(text: string): string {
  return text
    .replace(/\[\[|\]\]/g, " ")
    .replace(/https?:\/\/\S+/g, "a link")
    .replace(/^\s{0,3}#{1,6}\s+/gm, "")
    .replace(/^\s*[-*+]\s+/gm, "")
    .replace(/^\s*\d+[.)]\s+/gm, "")
    .replace(/[*_`]+/g, "")
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
  let uttered = 0;

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

  function hush(): void {
    buffers.think = "";
    buffers.speak = "";
    writeFileSync(STOP, "", "utf8");
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
    // A restart mid-ride would otherwise reuse numbers the watcher has not
    // drained yet, and the new utterances would sort behind the stale ones.
    for (const name of readdirSync(SPOOL)) {
      const n = Number.parseInt(name.slice(0, 6), 10);
      if (Number.isFinite(n) && n > seq) seq = n;
    }

    if (ctx.hasUI) {
      ctx.ui.setStatus("domestique", ctx.ui.theme.fg("accent", "domestique"));
    }
  });

  pi.on("message_start", (event, _ctx) => {
    if (!enabled) return;
    const message = event.message as { role?: string } | undefined;
    if (message?.role !== "assistant") return;
    // The budget bounds one spoken chunk, not one exchange. A tool-heavy turn
    // produces several assistant messages and each gets its own allowance.
    spokenChars = 0;
    responseMuted = false;
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
      case "text_delta": {
        if (typeof delta.delta !== "string") return;
        if (responseMuted) return;
        const fence = (buffers.speak + delta.delta).indexOf("```");
        if (fence < 0) {
          feed("speak", delta.delta);
          return;
        }
        // Fenced code cannot be read aloud usefully. Speak up to the fence,
        // then hand the rest to the screen.
        buffers.speak = (buffers.speak + delta.delta).slice(0, fence);
        drain("speak");
        if (!responseMuted) {
          codeSuppressed += 1;
          mute("Code on screen.");
        }
        return;
      }
      case "text_end":
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

  pi.registerCommand("domestique", {
    description: "Show domestique speech-spool counters",
    handler: (_args, ctx) => {
      if (!enabled) {
        ctx.ui.notify("domestique: disabled (pass --domestique)", "info");
        return;
      }
      let pending = 0;
      try {
        pending = readdirSync(SPOOL).filter((n) => n.endsWith(".txt")).length;
      } catch {
        // The watcher owns this directory; if it is gone, so is the audio.
      }
      ctx.ui.notify(
        [
          `domestique: active, spool ${SPOOL}`,
          `utterances written: ${uttered}, pending: ${pending}`,
          `responses truncated at ${RESPONSE_CHAR_BUDGET} chars: ${truncated}`,
          `responses cut at a code fence: ${codeSuppressed}`,
        ].join("\n"),
        "info",
      );
    },
  });

  // The watcher outlives pi, so an exit has to silence the ticker itself.
  // The response still drains: in --print mode pi is gone before the answer
  // has finished speaking.
  pi.on("session_shutdown", () => {
    if (enabled) quietThinking();
  });
}
