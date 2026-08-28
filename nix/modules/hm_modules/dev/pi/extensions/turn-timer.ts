/**
 * turn-timer: wall-clock elapsed time on the streaming working row.
 *
 * The working row is the one surface that exists exactly as long as the
 * work does, and it already redraws at the spinner's interval, so
 * ctx.ui.setWorkingMessage() (docs/extensions.md, "Widgets, Status, and
 * Footer") is nearly free to keep current. Loader.setMessage() calls
 * ui.requestRender() itself. The footer alternative would tick a line
 * five other extensions already share.
 *
 * The clock spans one prompt-to-idle stretch, which is what "turn" means
 * here and not what pi's turn_start/turn_end mean: agent_start fires
 * again for every auto-retry, auto-compaction and queued follow-up
 * inside a single run (docs/extensions.md, "agent_start / agent_end /
 * agent_settled"), so the start time is taken only when no clock is
 * already running, and agent_settled is what clears it. That event is
 * emitted from a finally block (AgentSession._runAgentPrompt), so an
 * interrupt or an error stops the clock too.
 *
 * "Working..." is pi's own defaultWorkingMessage, restated because
 * setWorkingMessage replaces the message rather than extending it and no
 * getter exposes the default. pi wraps whatever it gets in
 * theme.fg("muted"), so there is no color to set here.
 *
 * Retry and compaction swap in their own status indicators, which keep
 * their built-in text; the timer returns with the working row.
 *
 * Seconds are rounded, not floored: a 1000ms interval fires a millisecond
 * either side of the boundary, and flooring a tick that lands at 999ms
 * repeats a second and then skips one (0s, 0s, 2s).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const TICK_MS = 1000;

function elapsed(ms: number): string {
  const total = Math.round(ms / 1000);
  const seconds = total % 60;
  const minutes = Math.floor(total / 60) % 60;
  const hours = Math.floor(total / 3600);
  if (hours > 0) return `${hours}h${String(minutes).padStart(2, "0")}m`;
  if (minutes > 0) return `${minutes}m${String(seconds).padStart(2, "0")}s`;
  return `${seconds}s`;
}

export default function (pi: ExtensionAPI) {
  let startedAt: number | undefined;
  let tick: ReturnType<typeof setInterval> | undefined;

  pi.on("agent_start", (_event, ctx) => {
    if (!ctx.hasUI || startedAt !== undefined) return;
    const start = Date.now();
    startedAt = start;
    const show = (): void =>
      ctx.ui.setWorkingMessage(`Working... ${elapsed(Date.now() - start)}`);
    show();
    tick = setInterval(show, TICK_MS);
  });

  pi.on("agent_settled", (_event, ctx) => {
    if (tick !== undefined) clearInterval(tick);
    tick = undefined;
    startedAt = undefined;
    if (ctx.hasUI) ctx.ui.setWorkingMessage();
  });
}
