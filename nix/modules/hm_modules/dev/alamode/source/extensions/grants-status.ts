/**
 * grants-status: the sandbox's carried grants as a footer chip.
 *
 * grants.ts mirrors ALAMODE_GRANTS into the system prompt, where only the model
 * reads it; this surfaces the same record where the human glances, so a
 * session that cannot reach the nix daemon, the ssh agent or the network
 * says so in the footer before a refusal has to. Same wrapper contract:
 * ALAMODE_GRANTS names the grants carried, ALAMODE_AVAILABLE_GRANTS is exported for
 * every sandboxed wrapper invocation, ALAMODE_ALLOWED_HOSTS lists the --allow
 * hosts. "grants: none" marks the closed sandbox; silence means the wrapper
 * did not run and grants do not apply.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function splitNames(value: string | undefined): string[] {
  return (value ?? "").split(",").filter((name) => name !== "");
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    if (!ctx.hasUI) return;
    const carried = splitNames(process.env.ALAMODE_GRANTS);
    const hosts = splitNames(process.env.ALAMODE_ALLOWED_HOSTS);
    if (
      carried.length === 0 &&
      hosts.length === 0 &&
      process.env.ALAMODE_AVAILABLE_GRANTS === undefined
    )
      return;
    const parts = [
      carried.join(","),
      hosts.length > 0 ? `+${hosts.join(",")}` : "",
    ].filter((part) => part !== "");
    ctx.ui.setStatus(
      "grants",
      parts.length > 0
        ? `grants: ${parts.join(" ")}`
        : ctx.ui.theme.fg("dim", "grants: none"),
    );
  });
}
