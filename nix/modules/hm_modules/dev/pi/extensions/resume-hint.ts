import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.on("session_shutdown", (event, ctx) => {
    if (event.reason !== "quit" || !ctx.hasUI || !process.stdout.isTTY) return;
    if (process.env.PI_COORD_ROLE === "child") return;
    const id = process.env.PI_SESSION_ID;
    if (!id || !/^[A-Za-z0-9_-]+$/.test(id)) return;
    process.stdout.write(
      `\x1b[2mTo resume with its grants:\x1b[22m pi --resume-session ${id}\n`,
    );
  });
}
