/**
 * grants: policy-matched prompt guidance.
 *
 * The sandbox wrapper exports ALAMODE_GRANTS ("nix,kagi,...") naming every grant
 * the invocation carries, and ALAMODE_AVAILABLE_GRANTS naming every grant it
 * could have carried: the built-in flags plus the configured bundles. This
 * appends each carried grant's markdown from ~/.pi/agent/grants/<name>.md to
 * the system prompt, so guidance arrives with the capability instead of
 * living in AGENTS.md, where it would either describe tools a strict session
 * cannot reach or bury the security contract of one it can. A grant with no
 * file is policy-only (the toolchain bundles) and stays silent.
 *
 * Delivery is through systemPromptOptions.sections, never a returned
 * systemPrompt. Two reasons, both measured on pi 1.0.0:
 *
 *   - A returned prompt replaces the whole assembled prompt for the run, so
 *     any section another extension sets is silently dropped (a probe marker
 *     set alongside a return never reached the provider), and no later
 *     handler can see the replacement either: every handler is handed the
 *     same base prompt. Sections compose in both directions.
 *   - Sections are the assembled prompt's own pipeline: what lands in the
 *     provider request also lands in the session file's structured record,
 *     so a human can audit any transcript for whether the grants guidance
 *     was in it. A forced prompt is invisible by construction.
 *
 * It then lists the grants the session does not carry, one line each, so a
 * session the sandbox blocks knows a flag exists and asks for /regrant
 * instead of retrying into the refusal or inventing a workaround. Grants are
 * read at launch and the sandbox cannot widen mid-session, which is why the
 * protocol is ask, don't act. After a regrant, ALAMODE_REGRANTED says what
 * changed, so the transcript's earlier refusals are not taken as current.
 *
 * Both vars ride the environment, so task.ts subagents ($ALAMODE_REAL_BIN
 * children of this process) see the same catalog the parent session does,
 * and the sections this writes reach their prompts too.
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
    const carried = splitNames(process.env.ALAMODE_GRANTS);
    const available = splitNames(process.env.ALAMODE_AVAILABLE_GRANTS);

    const docs: string[] = [];
    const headings = new Map<string, string>();
    for (const name of [...new Set([...carried, ...available])]) {
      const file = join(dir, `${name}.md`);
      if (!existsSync(file)) continue;
      const md = readFileSync(file, "utf8").trim();
      headings.set(name, md.match(/^# (.+)$/m)?.[1] ?? name);
      if (carried.includes(name)) docs.push(md);
    }

    const sections = event.systemPromptOptions.sections;
    const regranted = process.env.ALAMODE_REGRANTED;
    if (regranted) {
      sections.regranted_capabilities =
        "# Grants changed\n\n" +
        `The human changed this session's grants before this launch: ${regranted}. ` +
        "Earlier turns ran under the old grants, so a refusal there may not " +
        "hold now, and work that relied on a dropped grant will be refused.";
    }
    if (docs.length > 0) {
      sections.granted_capabilities =
        "# Granted capabilities and their costs\n\n" + docs.join("\n\n");
    }

    const missing = available.filter((name) => !carried.includes(name));
    if (missing.length > 0) {
      const lines = missing.map(
        (name) =>
          `- ${name === "web" ? "--web" : `--allow-${name}`}${headings.has(name) ? ` (${headings.get(name)})` : ""}`,
      );
      sections.missing_grants =
        "# Grants this session does not carry\n\n" +
        "These flags were not given to this invocation. Flags are read at launch, " +
        "so the sandbox cannot widen mid-session: when work needs one, or a " +
        "command fails the way the sandbox refusing something looks, name " +
        "the flag and ask the human to run /regrant with it, which restarts " +
        "this session with the grants they choose; the conversation and " +
        "worktree carry over. Do not " +
        "retry the refused command or work around it.\n\n" +
        lines.join("\n") +
        "\n\nWider than any name: `--allow <host>` adds one network host, " +
        "`--allow-read <path>` and `--allow-write <path>` add filesystem " +
        "read access or read/write access, `--allow-rw <path>` also adds both, " +
        "`--listen <port>` permits one loopback listener, and `--web` permits " +
        "public web destinations without changing filesystem permissions.";
    }
  });
}
