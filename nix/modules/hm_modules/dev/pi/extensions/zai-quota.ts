/**
 * zai-quota: GLM Coding Plan quota in the footer, styled like the Claude Code
 * statusline (dev/claude-code/statusline.sh): `GLM 5h 12% (2:43p) · 7d 3% (26h)`.
 *
 * The endpoint is undocumented. It is the one zai-org's own glm-plan-usage
 * plugin queries (github.com/zai-org/zai-coding-plugins,
 * plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs),
 * which still only knows the older TOKENS_LIMIT entries. The credits plan
 * (docs.z.ai/devpack/notice/usage-revision) answers with CREDIT_LIMIT entries
 * instead; both carry the window as `unit` plus `number`, where unit 3 is
 * hours and unit 6 is weeks, `percentage` as percent used, and
 * `nextResetTime` in epoch milliseconds.
 *
 * Inert without a `zai` key, so hosts that never ran `/login zai` show nothing.
 */

import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

const QUOTA_URL = "https://api.z.ai/api/monitor/usage/quota/limit";
const REFRESH_MS = 2 * 60 * 1000;
const WINDOW_TYPES = new Set(["CREDIT_LIMIT", "TOKENS_LIMIT"]);

interface Limit {
  type: string;
  unit: number;
  number: number;
  percentage: number;
  nextResetTime?: number;
}

function windowLabel(l: Limit): string | undefined {
  if (l.unit === 3) return `${l.number}h`;
  if (l.unit === 6) return `${l.number * 7}d`;
  return undefined;
}

// Same shape as statusline.sh's format_reset_time: clock time inside a day,
// whole hours beyond it, nothing once the reset has passed.
function resetLabel(ms: number | undefined, now: number): string {
  if (!ms || ms <= now) return "";
  const diff = ms - now;
  if (diff > 86_400_000) return `(${Math.floor(diff / 3_600_000)}h)`;
  const d = new Date(ms);
  const h = d.getHours() % 12 || 12;
  const m = String(d.getMinutes()).padStart(2, "0");
  return `(${h}:${m}${d.getHours() < 12 ? "a" : "p"})`;
}

async function fetchLimits(apiKey: string): Promise<Limit[]> {
  const res = await fetch(QUOTA_URL, {
    headers: { Authorization: apiKey, "Accept-Language": "en-US,en" },
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const body = (await res.json()) as { data?: { limits?: Limit[] } };
  return (body.data?.limits ?? []).filter((l) => WINDOW_TYPES.has(l.type));
}

function render(ctx: ExtensionContext, limits: Limit[]): string | undefined {
  const { theme } = ctx.ui;
  const now = Date.now();
  const segments = limits
    .map((l) => ({ l, label: windowLabel(l) }))
    .filter((x): x is { l: Limit; label: string } => x.label !== undefined)
    .sort((a, b) => a.l.unit - b.l.unit || a.l.number - b.l.number)
    .map(({ l, label }) => {
      const pct = Math.round(l.percentage);
      const color = pct >= 90 ? "error" : pct >= 70 ? "warning" : "success";
      const reset = resetLabel(l.nextResetTime, now);
      return `${label} ${theme.fg(color, `${pct}%`)}${reset ? " " + theme.fg("dim", reset) : ""}`;
    });
  if (segments.length === 0) return undefined;
  return `GLM ${segments.join(theme.fg("dim", " · "))}`;
}

export default function (pi: ExtensionAPI) {
  let timer: ReturnType<typeof setInterval> | undefined;

  pi.on("session_start", (_event, ctx) => {
    if (!ctx.hasUI) return;
    const refresh = async () => {
      const apiKey = await ctx.modelRegistry.getApiKeyForProvider("zai");
      if (!apiKey) return;
      try {
        ctx.ui.setStatus("zai-quota", render(ctx, await fetchLimits(apiKey)));
      } catch {
        ctx.ui.setStatus(
          "zai-quota",
          `GLM ${ctx.ui.theme.fg("dim", "quota unavailable")}`,
        );
      }
    };
    void refresh();
    timer = setInterval(() => void refresh(), REFRESH_MS);
  });

  pi.on("session_shutdown", () => {
    if (timer) clearInterval(timer);
    timer = undefined;
  });
}
