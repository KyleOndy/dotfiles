import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// The wrapper lands only commits when the session exits, so edits left
// uncommitted would stay behind in the session's private worktree.
export default function (pi: ExtensionAPI) {
  pi.on("session_shutdown", async (event, ctx) => {
    if (event.reason !== "quit" || !process.env.ALAMODE_SESSION_ID) return;
    if (process.env.ALAMODE_COORD_ROLE === "child") return;
    // A regrant relaunches pi on this worktree without landing anything.
    if (process.env.ALAMODE_REGRANTING) return;
    const git = (...args: string[]) => pi.exec("git", args, { cwd: ctx.cwd });
    const status = await git("status", "--porcelain");
    if (status.code !== 0 || !status.stdout.trim()) return;
    let result = await git("add", "--all");
    if (result.code === 0)
      result = await git(
        "commit",
        "--quiet",
        "--no-verify",
        "--message",
        "wip: uncommitted at exit",
      );
    if (result.code !== 0) {
      const id = process.env.ALAMODE_SESSION_ID;
      process.stderr.write(
        `alamode: Could not commit the session's leftover edits, so they stay\n` +
          `alamode: uncommitted in ${ctx.cwd}: ${result.stderr.trim()}\n` +
          (/^[A-Za-z0-9_-]+$/.test(id)
            ? `alamode:\nalamode:   resume  alamode resume ${id}\n`
            : ""),
      );
    }
  });
}
