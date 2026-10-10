/**
 * resume-hint: the session's grants as a relaunch command, printed above
 * pi's own "To resume this session" hint, which resumes without them.
 *
 * pi hardcodes that hint in InteractiveMode.shutdown(), but emits
 * session_shutdown after stopping the TUI and before printing it. The wrapper
 * does not record path grants, --allow-loopback, --allow-trustd or
 * --allow-git-write, so the command lacks them. The broker launches a
 * coordinator child with flags no human retypes, so a child prints nothing.
 */

import { existsSync } from "node:fs";
import { basename } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function splitNames(value: string | undefined): string[] {
  return (value ?? "").split(",").filter((name) => name !== "");
}

function grantFlags(): string[] {
  const flags = splitNames(process.env.PI_GRANTS).map((grant) => {
    if (grant === "coordinator")
      return `--coordinator=${basename(process.env.PI_COORD_DIR ?? "")}`;
    if (grant === "forge" && process.env.FORGE_INSTANCE)
      return `--allow-forge=${process.env.FORGE_INSTANCE}`;
    return `--allow-${grant}`;
  });
  for (const host of splitNames(process.env.PI_ALLOWED_HOSTS))
    flags.push("--allow", host);
  return flags;
}

export default function (pi: ExtensionAPI) {
  pi.on("session_shutdown", (event, ctx) => {
    if (event.reason !== "quit" || !ctx.hasUI || !process.stdout.isTTY) return;
    if (process.env.PI_COORD_ROLE === "child") return;
    // pi prints its hint only once the session file exists.
    const sessionFile = ctx.sessionManager.getSessionFile();
    if (!sessionFile || !existsSync(sessionFile)) return;
    const flags = grantFlags();
    if (flags.length === 0) return;
    const command = [
      "pi",
      ...flags,
      "--session",
      ctx.sessionManager.getSessionId(),
    ];
    process.stdout.write(
      `\x1b[2mTo resume with its grants:\x1b[22m ${command.join(" ")}\n`,
    );
  });
}
