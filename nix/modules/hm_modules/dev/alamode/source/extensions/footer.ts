/**
 * footer: pi's three footer lines as two.
 *
 * The first line says where the session is and what it runs: the launch
 * branch and checkout, the session name, a context meter with its token
 * count against the window, and the model.
 * The second carries the other extensions' statuses on the left, and on the
 * right the lines the session has changed, its tokens, cost and clock.
 * Labels are dim and values full
 * brightness, so the numbers stand out without background colors.
 *
 * Under the wrapper pi's cwd is the private worktree on alamode-<id>, so
 * ALAMODE_SOURCE and ALAMODE_SOURCE_BRANCH name the checkout the session
 * came from. Without them (pi run bare) the footer shows the cwd and the
 * live branch. A checkout directory named after its branch, as a worktree
 * of a bare repo usually is, is shown by its parent, so the branch is
 * named once.
 *
 * The meter turns warning above 70% and error above 90%, the cutoffs pi's
 * own footer colors its percentage at (FooterComponent.render). The model
 * marker takes the thinking level's color, which is the editor border's.
 *
 * Token totals walk every session entry the way pi's footer does, and the
 * footer renders on every working-indicator frame, so they are cached on
 * the entry count.
 *
 * A status that reads "name: value" is drawn with the name dim. Statuses
 * are sorted by key, as pi sorts them.
 *
 * Lines changed are counted against ALAMODE_SNAPSHOT_COMMIT, the commit
 * the session started at (HEAD under bare pi), working tree included and
 * untracked files too, since wip-on-exit.ts commits both at quit. They are
 * recounted after every tool call, as bash changes files as well as edit
 * and write do.
 *
 * The session clock counts from this pi process's session_start, so a
 * resumed session starts again at zero. The footer redraws with the
 * working indicator, and once a minute while idle so the clock moves.
 */

import type {
  ExtensionAPI,
  ExtensionContext,
  Theme,
} from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { readFile, stat } from "node:fs/promises";
import path from "node:path";

const METER_CELLS = 12;
const UNTRACKED_MAX_FILES = 200;
const UNTRACKED_MAX_BYTES = 1 << 20;
const BRANCH_GLYPH = "";

interface Usage {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  cost: { total: number };
}

interface Totals {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  cost: number;
  // Percent of the latest prompt served from cache; undefined before the
  // first assistant message.
  hitRate?: number;
}

function count(n: number): string {
  if (n < 1000) return String(n);
  if (n < 10_000) return `${(n / 1000).toFixed(1)}k`;
  if (n < 1_000_000) return `${Math.round(n / 1000)}k`;
  return `${(n / 1_000_000).toFixed(1)}M`;
}

function sum(entries: readonly unknown[]): Totals {
  const totals: Totals = {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    cost: 0,
  };
  const add = (usage: Usage | undefined): void => {
    if (!usage) return;
    totals.input += usage.input;
    totals.output += usage.output;
    totals.cacheRead += usage.cacheRead;
    totals.cacheWrite += usage.cacheWrite;
    totals.cost += usage.cost.total;
  };
  for (const entry of entries as {
    type: string;
    usage?: Usage;
    message?: { role: string; usage?: Usage };
  }[]) {
    if (entry.type === "usage") add(entry.usage);
    else if (entry.type === "branch_summary" || entry.type === "compaction")
      add(entry.usage);
    else if (entry.type === "message") {
      add(entry.message?.usage);
      const usage = entry.message?.usage;
      if (entry.message?.role === "assistant" && usage) {
        const prompt = usage.input + usage.cacheRead + usage.cacheWrite;
        totals.hitRate =
          prompt > 0 ? (usage.cacheRead / prompt) * 100 : undefined;
      }
    }
  }
  return totals;
}

interface Changed {
  added: number;
  removed: number;
}

// --no-optional-locks keeps diff from refreshing the index, which would take
// index.lock out from under the agent's own git. An untracked file counts
// as all added lines unless it is binary, as numstat skips one, or too large
// to read on every tool call.
async function changed(
  pi: ExtensionAPI,
  cwd: string,
  base: string,
): Promise<Changed | undefined> {
  const git = (...args: string[]) =>
    pi.exec("git", ["--no-optional-locks", ...args], { cwd });
  const diff = await git("diff", "--numstat", base);
  if (diff.code !== 0) return undefined;
  const total = { added: 0, removed: 0 };
  for (const line of diff.stdout.split("\n")) {
    const [added, removed] = line.split("\t");
    total.added += Number(added) || 0;
    total.removed += Number(removed) || 0;
  }
  const untracked = await git(
    "ls-files",
    "--others",
    "--exclude-standard",
    "-z",
  );
  const files = untracked.stdout
    .split("\0")
    .filter((file) => file !== "")
    .slice(0, UNTRACKED_MAX_FILES);
  for (const file of files) {
    const full = path.join(cwd, file);
    try {
      if ((await stat(full)).size > UNTRACKED_MAX_BYTES) continue;
      const text = await readFile(full, "utf8");
      if (text === "" || text.includes("\0")) continue;
      total.added += text.split("\n").length - (text.endsWith("\n") ? 1 : 0);
    } catch {
      // Deleted between the listing and the read.
    }
  }
  return total;
}

function clock(ms: number): string {
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 1) return "<1m";
  if (minutes < 60) return `${minutes}m`;
  return `${Math.floor(minutes / 60)}h${String(minutes % 60).padStart(2, "0")}m`;
}

function spread(left: string, right: string, width: number): string {
  const room = width - visibleWidth(right) - 2;
  if (room < 8) return truncateToWidth(`${left}  ${right}`, width, "...");
  const fitted = truncateToWidth(left, room, "...");
  return (
    fitted +
    " ".repeat(width - visibleWidth(fitted) - visibleWidth(right)) +
    right
  );
}

function status(theme: Theme, text: string): string {
  const flat = text.replace(/[\r\n\t]+/g, " ");
  const named = /^([\w-]+): (.+)$/.exec(flat);
  return named && !flat.includes("\x1b")
    ? `${theme.fg("dim", named[1])} ${named[2]}`
    : flat;
}

export default function (pi: ExtensionAPI) {
  let recount: (() => void) | undefined;
  pi.on("tool_execution_end", () => recount?.());

  pi.on("session_start", (_event, ctx: ExtensionContext) => {
    if (!ctx.hasUI) return;
    let cached: { entries: number; totals: Totals } | undefined;
    const started = Date.now();
    const base = process.env.ALAMODE_SNAPSHOT_COMMIT ?? "HEAD";
    let diffstat: Changed | undefined;
    let redraw = (): void => {};
    // One count at a time; calls made while one runs fold into one more.
    let counting = false;
    let stale = false;
    recount = async () => {
      if (counting) {
        stale = true;
        return;
      }
      counting = true;
      try {
        do {
          stale = false;
          diffstat = await changed(pi, ctx.cwd, base);
        } while (stale);
      } finally {
        counting = false;
      }
      redraw();
    };
    recount();

    ctx.ui.setFooter((tui, theme, footerData) => {
      const unsubscribe = footerData.onBranchChange(() => tui.requestRender());
      const tick = setInterval(() => tui.requestRender(), 60_000);
      redraw = () => tui.requestRender();
      return {
        dispose() {
          clearInterval(tick);
          unsubscribe();
        },
        invalidate() {},
        render(width: number): string[] {
          const dim = (text: string): string => theme.fg("dim", text);

          const branch =
            process.env.ALAMODE_SOURCE_BRANCH ?? footerData.getGitBranch();
          const checkout = process.env.ALAMODE_SOURCE ?? ctx.cwd;
          const where =
            branch && path.basename(checkout) === branch
              ? path.dirname(checkout)
              : checkout;
          const name = pi.getSessionName();
          const place = [
            branch ? theme.fg("borderAccent", `${BRANCH_GLYPH} ${branch}`) : "",
            dim(name ? `${where} · ${name}` : where),
          ]
            .filter((part) => part !== "")
            .join("  ");

          const usage = ctx.getContextUsage();
          const percent = usage?.percent ?? null;
          const level =
            percent === null
              ? "dim"
              : percent > 90
                ? "error"
                : percent > 70
                  ? "warning"
                  : "success";
          const filled =
            percent === null
              ? 0
              : Math.min(
                  METER_CELLS,
                  Math.round((percent / 100) * METER_CELLS),
                );
          const meter =
            theme.fg(level, "━".repeat(filled)) +
            theme.fg("borderMuted", "━".repeat(METER_CELLS - filled));
          const shown =
            percent === null
              ? dim("?")
              : level === "success"
                ? `${Math.round(percent)}%`
                : theme.fg(level, `${Math.round(percent)}%`);
          const tokens = usage
            ? ` ${usage.tokens === null ? dim("?") : count(usage.tokens)}${dim(`/${count(usage.contextWindow)}`)}`
            : "";

          const thinking = pi.getThinkingLevel();
          const model = ctx.model
            ? theme.getThinkingBorderColor(thinking)("▌") +
              ctx.model.id +
              (ctx.model.reasoning ? ` ${dim(thinking)}` : "")
            : dim("no model");

          const lines = [
            spread(
              place,
              `${dim("ctx")} ${meter} ${shown}${tokens}   ${model}`,
              width,
            ),
          ];

          const entries = ctx.sessionManager.getEntries();
          if (cached?.entries !== entries.length)
            cached = { entries: entries.length, totals: sum(entries) };
          const { totals } = cached;
          const spend = [
            diffstat && (diffstat.added || diffstat.removed)
              ? `${theme.fg("success", `+${diffstat.added}`)} ${theme.fg("error", `-${diffstat.removed}`)}`
              : "",
            totals.input || totals.output
              ? `${dim("↑")}${count(totals.input)} ${dim("↓")}${count(totals.output)}`
              : "",
            totals.hitRate !== undefined && totals.cacheRead + totals.cacheWrite
              ? `${dim("cache")} ${Math.round(totals.hitRate)}%`
              : "",
            // Below a cent, cents would round a short session to $0.00.
            totals.cost
              ? `${dim("$")}${totals.cost.toFixed(totals.cost < 0.01 ? 4 : 2)}`
              : "",
            dim(clock(Date.now() - started)),
          ]
            .filter((part) => part !== "")
            .join("  ");

          const statuses = [...footerData.getExtensionStatuses()]
            .sort(([a], [b]) => a.localeCompare(b))
            .map(([, text]) => status(theme, text))
            .join("   ");

          lines.push(spread(statuses, spend, width));
          return lines;
        },
      };
    });
  });
}
