/**
 * header: a slice of pie à la mode beside the alamode wordmark, with the
 * session id and where quitting lands its commits.
 *
 * The slice is 20x10 pixel art drawn two pixels to a cell: "▀" with the
 * top pixel as foreground and the bottom one as background. Its colors are
 * gruvbox truecolor literals rather than theme tokens, since they draw a
 * pie, not a UI role. The wordmark and labels use the theme.
 *
 * pi installs a custom header only in place of its built-in one, which it
 * skips under quietStartup: true (InteractiveMode.setExtensionHeader
 * returns early without builtInHeader), so settings.json sets "header".
 *
 * ALAMODE_LANDING_SHORT is landing_notice()'s forecast as a clause
 * (nix/pkgs/alamode-runtime/session.py); a warning's full sentence also
 * arrives as landing-notice.ts's toast. Without ALAMODE_SESSION_ID the wrapper did
 * not run, and only the art and wordmark are drawn.
 */

import { type ExtensionAPI, VERSION } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

const ART = [
  "..........WWWW......",
  ".........WWWWWW..kk.",
  "........wWwWwWwKKKKk",
  "......KRKRKRKRKRKKKk",
  "....RKRKRKRKRKRKKKKk",
  "..KRKRKRKRKRKRKRKKKk",
  "KKKKKKKKKKKKKKKKKKKk",
  "RRRrRRRRRrRRRRRRrRKk",
  "RrRRRRrRRRRRrRRRRRKk",
  "kkkkkkkkkkkkkkkkkkkk",
];

const PIXELS: Record<string, string> = {
  W: "251;241;199",
  w: "213;196;161",
  K: "215;153;33",
  k: "181;118;20",
  R: "204;36;29",
  r: "157;0;6",
};

const WORDMARK = [
  "▄▀█ █   ▄▀█ █▀▄▀█ █▀█ █▀▄ █▀▀",
  "█▀█ █▄▄ █▀█ █ ▀ █ █▄█ █▄▀ ██▄",
];

function cell(top: string | undefined, bottom: string | undefined): string {
  if (!top && !bottom) return " ";
  if (!top) return `\x1b[38;2;${bottom}m▄\x1b[39m`;
  if (!bottom) return `\x1b[38;2;${top}m▀\x1b[39m`;
  return `\x1b[38;2;${top}m\x1b[48;2;${bottom}m▀\x1b[39;49m`;
}

const SLICE = Array.from({ length: ART.length / 2 }, (_, row) =>
  [...ART[2 * row]]
    .map((pixel, x) => cell(PIXELS[pixel], PIXELS[ART[2 * row + 1][x]]))
    .join(""),
);

function pad(text: string, width: number): string {
  return text + " ".repeat(Math.max(0, width - visibleWidth(text)));
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    if (!ctx.hasUI) return;
    const id = process.env.ALAMODE_SESSION_ID;
    const lands = process.env.ALAMODE_LANDING_SHORT;
    const warning = process.env.ALAMODE_LANDING_LEVEL === "warning";

    ctx.ui.setHeader((_tui, theme) => ({
      invalidate() {},
      render(width: number): string[] {
        const dim = (text: string): string => theme.fg("dim", text);
        const name = pi.getSessionName();
        const middle = [
          "",
          "",
          theme.fg("accent", WORDMARK[0]),
          theme.fg("accent", WORDMARK[1]),
          dim(`pi ${VERSION}`),
        ];
        const info = [
          "",
          "",
          id ? `${dim("session")}  ${id}${name ? dim(" · ") + name : ""}` : "",
          lands
            ? `${dim("lands  ")}  ${theme.fg(warning ? "warning" : "success", lands)}`
            : "",
          "",
        ];
        return [
          ...SLICE.map((art, row) =>
            truncateToWidth(
              `${art}  ${pad(middle[row], WORDMARK[0].length)}    ${info[row]}`,
              width,
              "",
            ),
          ),
          "",
        ];
      },
    }));
  });
}
