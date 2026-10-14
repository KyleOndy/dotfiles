/**
 * thinking-time: record the wall-clock time each request spends thinking.
 *
 * pi persists every assistant message with its usage and one durationMs
 * for the whole request (docs/message-types.md), so `alamode stats` can
 * derive tokens, cost and request time from the session records alone.
 * What no record carries is how much of a request the model spent
 * reasoning: the phase is only visible while it streams, and the finished
 * message cannot say when it ended.
 *
 * The agent loop delivers the stream as message_update events carrying
 * pi's own normalized assistantMessageEvent (docs/json.md names
 * thinking_start and thinking_end), so no provider wire format is parsed
 * here: whatever API served the request, the phase looks the same. Each
 * thinking block is timed from its start to its end and the blocks are
 * summed, so text streamed between two thinking blocks is charged to
 * neither, and a request aborted inside its thinking is closed at
 * message_end and keeps the time it spent.
 *
 * The measurement is a custom entry in the session file itself, written
 * through pi.appendEntry (docs/extensions.md: durable data excluded from
 * model context), beside the messages it belongs to: resume replays it
 * as inert data and `alamode stats` folds it into its THINKING column,
 * so no second ledger exists to drift from the records it summarizes.
 *
 * Only a request that streamed a thinking block is recorded. A provider
 * that reasons silently, the way OpenAI's o-series does over chat
 * completions, still reports its reasoning tokens in usage.reasoning,
 * but no wall time can be seen from here; a request that never thought
 * writes nothing. Best effort throughout: a run that keeps no session
 * file (alamode's --no-session task subagents) still appends, into an
 * in-memory session that dies with the process, so the measurement is
 * dropped with it, never the turn; the append is guarded because a mode
 * that cannot record at all must cost nothing.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const ENTRY_TYPE = "thinking-time";

interface StreamUpdate {
  type?: string;
}

interface AssistantMessage {
  role?: string;
  provider?: string;
  model?: string;
  responseModel?: string;
}

export default function (pi: ExtensionAPI) {
  let blockStart: number | undefined;
  let thinkingMs = 0;

  const closeBlock = (): void => {
    if (blockStart !== undefined) {
      thinkingMs += Date.now() - blockStart;
      blockStart = undefined;
    }
  };

  pi.on("message_start", (event) => {
    // A retry starts a fresh provider stream (docs/json.md: the agent
    // loop translates provider-level start into message_start), so the
    // attempt in flight, and only it, is what gets measured.
    const message = (event as { message?: AssistantMessage }).message;
    if (message?.role !== "assistant") return;
    blockStart = undefined;
    thinkingMs = 0;
  });

  pi.on("message_update", (event) => {
    const update = (event as { assistantMessageEvent?: StreamUpdate })
      .assistantMessageEvent;
    if (update?.type === "thinking_start") {
      blockStart = blockStart ?? Date.now();
    } else if (update?.type === "thinking_end") {
      closeBlock();
    }
  });

  pi.on("message_end", (event) => {
    const message = (event as { message?: AssistantMessage }).message;
    if (message?.role !== "assistant") return;
    closeBlock();
    const served = message.responseModel ?? message.model;
    if (
      thinkingMs > 0 &&
      typeof message.provider === "string" &&
      typeof served === "string"
    ) {
      try {
        pi.appendEntry(ENTRY_TYPE, {
          thinkingMs: Math.round(thinkingMs),
          provider: message.provider,
          // The response model when the provider names one, matching how
          // the scan attributes each assistant message's usage.
          model: served,
        });
      } catch {
        // No session file to write; the measurement is lost, not the turn.
      }
    }
    blockStart = undefined;
    thinkingMs = 0;
  });
}
