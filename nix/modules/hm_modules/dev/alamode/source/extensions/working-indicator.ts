/**
 * working-indicator: a rising-bar glyph for the streaming working row.
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
 * Custom frames are rendered verbatim, bypassing the accent coloring
 * WorkingStatusIndicator applies to the default spinner, so each frame
 * carries its own theme.fg().
 *
 * Applied on session_start rather than once at load: /reload runs
 * resetExtensionUI(), which drops the indicator back to pi's default.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const FRAMES = [..."▁▂▃▄▅▆▇█▇▆▅▄▃▂"];

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    if (ctx.hasUI)
      ctx.ui.setWorkingIndicator({
        frames: FRAMES.map((frame) => ctx.ui.theme.fg("accent", frame)),
        intervalMs: 70,
      });
  });
}
