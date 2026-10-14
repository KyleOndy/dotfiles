/**
 * regrant: the sandbox is fixed for the life of a pi process, so /regrant
 * writes the grant flags to ALAMODE_REGRANT_REQUEST and quits. The wrapper
 * asks at the terminal and starts pi again on the same transcript and
 * worktree (confirm_regrant in nix/pkgs/alamode-runtime/session.py).
 *
 * pi 1.1.0 writes "To resume this session: pi --session ..." after
 * session_shutdown. That pi is not on PATH, and run directly it would skip
 * the sandbox, so the line is dropped.
 */

import { writeFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PI_RESUME_LINE = "To resume this session:";

function dropPiResumeLine() {
  const write = process.stdout.write.bind(process.stdout);
  process.stdout.write = ((chunk: any, ...rest: any[]) =>
    String(chunk).includes(PI_RESUME_LINE)
      ? true
      : write(chunk, ...rest)) as typeof process.stdout.write;
}

export default function (pi: ExtensionAPI) {
  pi.registerCommand("regrant", {
    description: "Relaunch this session with different grants",
    handler: async (args, ctx) => {
      const request = process.env.ALAMODE_REGRANT_REQUEST;
      if (!request) {
        ctx.ui.notify(
          "A coordinator and its agents keep their grants; start a new coordinator to change them.",
          "error",
        );
        return;
      }
      let flags = args.trim();
      if (!flags) {
        const edited = await ctx.ui.editor(
          "Grant flags, in place of this session's own",
          process.env.ALAMODE_GRANT_ARGS ?? "",
        );
        if (edited === undefined) return;
        flags = edited.trim();
      }
      writeFileSync(request, flags + "\n", { mode: 0o600 });
      // wip-on-exit.ts reads it: the relaunch keeps the worktree as it is.
      process.env.ALAMODE_REGRANTING = "1";
      ctx.shutdown();
    },
  });

  pi.on("session_shutdown", (event, ctx) => {
    const id = process.env.ALAMODE_SESSION_ID;
    if (event.reason !== "quit" || !id) return;
    dropPiResumeLine();
    if (!ctx.hasUI || !process.stdout.isTTY) return;
    if (process.env.ALAMODE_REGRANTING) return;
    if (process.env.ALAMODE_COORD_ROLE === "child") return;
    if (!/^[A-Za-z0-9_-]+$/.test(id)) return;
    const grants = process.env.ALAMODE_GRANT_ARGS || "GRANTS";
    process.stdout.write(
      `\x1b[2mTo resume with its grants:\x1b[22m alamode resume ${id}\n` +
        `\x1b[2mTo change its grants:\x1b[22m      alamode resume ${id} ${grants}\n`,
    );
  });
}
