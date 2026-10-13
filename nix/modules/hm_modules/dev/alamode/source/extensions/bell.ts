/**
 * bell: ring the host's notification sound once pi has waited on you for a
 * minute, as Claude Code's idle_prompt does.
 *
 * Waiting means the turn settled with no background job (stall-guard.ts).
 * A keystroke or a new turn cancels the ring, so a session you are watching
 * stays quiet, and the next settle starts the minute again.
 *
 * The sandbox denies CoreAudio (see domestique.ts), so the sound plays in the
 * relay outside it. alamode-relay's /tool/bell route takes the session's
 * relay token and an empty JSON body; the relay drops a ring inside 10s of
 * the last one. Without that route the variables are unset and this
 * extension does nothing, as in `--print` and the other non-TUI modes.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const IDLE_MS = 60_000;

const url = process.env.ALAMODE_BELL_URL;
const token = process.env.ALAMODE_BELL_TOKEN;

export default function (pi: ExtensionAPI) {
  if (!url || !token) return;

  let tui = false;
  let settled = false;
  let jobs = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;

  const ring = (): void => {
    timer = undefined;
    fetch(url, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: "{}",
    }).catch(() => {});
  };

  const cancel = (): void => {
    clearTimeout(timer);
    timer = undefined;
  };

  const arm = (): void => {
    cancel();
    if (tui && settled && jobs === 0) timer = setTimeout(ring, IDLE_MS);
  };

  pi.on("session_start", (_event, ctx) => {
    tui = ctx.mode === "tui";
    if (tui) {
      ctx.ui.onTerminalInput(() => {
        cancel();
        return undefined;
      });
    }
  });
  pi.on("session_shutdown", () => {
    tui = false;
    cancel();
  });

  pi.on("agent_start", () => {
    settled = false;
    cancel();
  });
  pi.on("agent_settled", () => {
    settled = true;
    arm();
  });
  pi.events.on("stall-guard:jobs", (count) => {
    jobs = Number(count);
    if (settled) arm();
  });
}
