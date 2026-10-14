import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// The wrapper exports where quitting will put the session's commits
// (landing_notice in nix/pkgs/alamode-runtime/session.py). It cannot print
// that itself: pi's fullscreen TUI covers anything written before it starts.
// header.ts already shows the forecast's short form, so only a warning, which
// says what will not move and why, is repeated in full.
export default function (pi: ExtensionAPI) {
  pi.on("session_start", (event, ctx) => {
    const notice = process.env.ALAMODE_LANDING;
    if (event.reason !== "startup" || !notice || !ctx.hasUI) return;
    if (process.env.ALAMODE_LANDING_LEVEL !== "warning") return;
    ctx.ui.notify(notice, "warning");
  });
}
