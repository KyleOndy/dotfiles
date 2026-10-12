/**
 * kagi-cost: fold Kagi API spend into pi's own cost accounting.
 *
 * pi prices a session from model token usage, so a paid API reached through
 * the bash tool is invisible: the footer and /session read the same whether a
 * turn made ten Kagi requests or none. docs/extensions.md ("tool_result")
 * lets a handler return a `usage` patch, and docs/rpc.md ("ToolResultMessage")
 * says a tool result's usage "contributes to session token and cost totals",
 * which is the hook that closes the gap.
 *
 * The amount comes from the `kagi` command itself (nix/pkgs/kagi/kagi.sh),
 * which prints one `kagi: billed $x.xxx` line per invocation on stderr. Two
 * reasons not to price the command line here instead: only kagi knows how
 * many units a call actually spent, once `read` started chunking urls into
 * requests of ten; and stderr survives a pipeline, so `kagi read url | head`
 * still reports, where parsing event.input.command would have to model
 * quoting, redirection and `&&` to get the same answer.
 *
 * Tokens stay zero because none were spent. Only cost.total moves, which is
 * what get_session_stats returns and what the footer and /session render.
 *
 * `pi --export` will not show any of it. Its computeStats
 * (export-html/template.js) accumulates usage only from messages whose role
 * is "assistant", so an exported transcript under-reports every tool-reported
 * charge, pi's own nested-LLM tools included. Nothing writable from here
 * changes that.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Dollars and cents are parsed apart and summed as mills ($0.001) so a turn
// with many calls cannot drift the way repeated float addition would.
const BILLED = /^kagi: billed \$(\d+)\.(\d{3})$/gm;

export default function (pi: ExtensionAPI) {
  pi.on("tool_result", (event) => {
    if (event.toolName !== "bash") return;

    const text = (event.content ?? [])
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("\n");

    let mills = 0;
    for (const match of text.matchAll(BILLED)) {
      mills += Number(match[1]) * 1000 + Number(match[2]);
    }
    if (mills === 0) return;

    const usage = event.usage ?? {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
    };
    const cost = usage.cost ?? {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      total: 0,
    };

    return {
      usage: {
        ...usage,
        cost: { ...cost, total: cost.total + mills / 1000 },
      },
    };
  });
}
