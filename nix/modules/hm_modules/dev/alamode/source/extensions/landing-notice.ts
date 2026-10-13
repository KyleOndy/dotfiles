import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// The wrapper exports where quitting will put the session's commits
// (landing_notice in nix/pkgs/alamode-runtime/session.py). It cannot print
// that itself: pi's fullscreen TUI covers anything written before it starts.
export default function (pi: ExtensionAPI) {
  pi.on("session_start", (event, ctx) => {
    const notice = process.env.ALAMODE_LANDING;
    if (event.reason !== "startup" || !notice || !ctx.hasUI) return;
    ctx.ui.notify(
      notice,
      process.env.ALAMODE_LANDING_LEVEL === "warning" ? "warning" : "info",
    );
  });
}
