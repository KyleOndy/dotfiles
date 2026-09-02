/**
 * grants: policy-matched prompt guidance.
 *
 * The sandbox wrapper exports PI_GRANTS ("nix,kagi,...") naming every grant
 * the invocation carries. This appends each grant's markdown from
 * ~/.pi/agent/grants/<name>.md to the system prompt, so guidance arrives
 * with the capability instead of living in AGENTS.md, where it would either
 * describe tools a strict session cannot reach or bury the security contract
 * of one it can. A grant with no file is policy-only (the toolchain bundles)
 * and stays silent.
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  type ExtensionAPI,
  getAgentDir,
} from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.on("before_agent_start", async (event) => {
    const names = (process.env.PI_GRANTS ?? "")
      .split(",")
      .filter((name) => name !== "");
    if (names.length === 0) return;

    const dir = join(getAgentDir(), "grants");
    const docs: string[] = [];
    for (const name of names) {
      const file = join(dir, `${name}.md`);
      if (existsSync(file)) docs.push(readFileSync(file, "utf8").trim());
    }
    if (docs.length === 0) return;

    return {
      systemPrompt:
        event.systemPrompt +
        "\n\n# Granted capabilities and their costs\n\n" +
        docs.join("\n\n"),
    };
  });
}
