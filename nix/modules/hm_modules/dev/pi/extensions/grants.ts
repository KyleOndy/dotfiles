/**
 * grants: policy-matched prompt guidance.
 *
 * The sandbox wrapper exports PI_GRANTS ("nix,kagi,...") naming every grant
 * the invocation carries, and PI_AVAILABLE_GRANTS naming every grant it
 * could have carried: the built-in flags plus the configured bundles. This
 * appends each carried grant's markdown from ~/.pi/agent/grants/<name>.md to
 * the system prompt, so guidance arrives with the capability instead of
 * living in AGENTS.md, where it would either describe tools a strict session
 * cannot reach or bury the security contract of one it can. A grant with no
 * file is policy-only (the toolchain bundles) and stays silent.
 *
 * It then lists the grants the session does not carry, one line each, so a
 * session the sandbox blocks knows a flag exists and asks for a restart
 * instead of retrying into the refusal or inventing a workaround. Grants are
 * read at launch and the sandbox cannot widen mid-session, which is why the
 * protocol is ask, don't act.
 *
 * Both vars ride the environment, so task.ts subagents ($PI_REAL_BIN
 * children of this process) see the same catalog the parent session does.
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  type ExtensionAPI,
  getAgentDir,
} from "@earendil-works/pi-coding-agent";

function splitNames(value: string | undefined): string[] {
  return (value ?? "").split(",").filter((name) => name !== "");
}

export default function (pi: ExtensionAPI) {
  pi.on("before_agent_start", async (event) => {
    const dir = join(getAgentDir(), "grants");
    const carried = splitNames(process.env.PI_GRANTS);
    const available = splitNames(process.env.PI_AVAILABLE_GRANTS);

    const docs: string[] = [];
    const headings = new Map<string, string>();
    for (const name of [...new Set([...carried, ...available])]) {
      const file = join(dir, `${name}.md`);
      if (!existsSync(file)) continue;
      const md = readFileSync(file, "utf8").trim();
      headings.set(name, md.match(/^# (.+)$/m)?.[1] ?? name);
      if (carried.includes(name)) docs.push(md);
    }

    let systemPrompt = event.systemPrompt;
    if (docs.length > 0) {
      systemPrompt +=
        "\n\n# Granted capabilities and their costs\n\n" + docs.join("\n\n");
    }

    const missing = available.filter((name) => !carried.includes(name));
    if (missing.length > 0) {
      const lines = missing.map(
        (name) =>
          `- ${name}${headings.has(name) ? ` (${headings.get(name)})` : ""}`,
      );
      systemPrompt +=
        "\n\n# Grants this session does not carry\n\n" +
        "Each of these is one `--allow-<name>` flag on the wrapper away, " +
        "and none was given to this invocation. Flags are read at launch, " +
        "so the sandbox cannot widen mid-session: when work needs one, or a " +
        "command fails the way the sandbox refusing something looks, name " +
        "the flag and ask the human to restart the session with it. Do not " +
        "retry the refused command or work around it.\n\n" +
        lines.join("\n") +
        "\n\nWider than any name: `--allow <host>` adds one network host, " +
        "`--allow-read <path>` and `--allow-write <path>` add filesystem " +
        "paths, `--allow-loopback` permits local binds, and `--web` lifts " +
        "the network restriction entirely while keeping reads allowlisted.";
    }

    return { systemPrompt };
  });
}
