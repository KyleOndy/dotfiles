/**
 * working-indicator: a wave of rising bars for the streaming working row.
 *
 * pi exposes no setting or theme key for the spinner, so ctx.ui
 * .setWorkingIndicator() (docs/tui.md, "Working Indicator Customization")
 * is the only lever.
 *
 * The frames are block elements from U+2581-U+2588. Alacritty draws
 * U+2500-U+259F with its own built-in font (builtin_box_drawing, default
 * true, alacritty(5)), so these land on the cell grid exactly at any font
 * size. Berkeley Mono 2.002 carries 454 codepoints and no braille block,
 * which is why pi's default spinner resolves through a CoreText fallback
 * face instead of the terminal font.
 *
 * The wave is WIDTH cells running the same bar cycle, each cell a step
 * behind the one to its left, so the crest travels left to right. Colors
 * are fixed per cell, two cells each of yellow, orange, red and purple
 * under gruvbox-dark, named by token so a theme change carries over.
 *
 * Custom frames are rendered verbatim, bypassing the accent coloring
 * WorkingStatusIndicator applies to the default spinner, so each frame
 * carries its own theme.fg().
 *
 * Applied on session_start rather than once at load: /reload runs
 * resetExtensionUI(), which drops the indicator back to pi's default.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const BARS = [..."▁▂▃▄▅▆▇█▇▆▅▄▃▂"];
const COLORS = ["accent", "thinkingXhigh", "error", "thinkingMax"] as const;
const WIDTH = 8;
const LAG = 2;

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    if (!ctx.hasUI) return;
    const { theme } = ctx.ui;
    const frames = BARS.map((_, step) =>
      Array.from({ length: WIDTH }, (_, cell) =>
        theme.fg(
          COLORS[Math.floor(cell / 2)],
          BARS[(step - cell * LAG + BARS.length * WIDTH) % BARS.length],
        ),
      ).join(""),
    );
    ctx.ui.setWorkingIndicator({ frames, intervalMs: 70 });
  });
}
