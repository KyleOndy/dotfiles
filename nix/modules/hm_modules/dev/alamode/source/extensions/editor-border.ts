/**
 * editor-border: the session's reach written into the editor's top border,
 * the one line always on screen beside where the human types.
 *
 * Left: the grants in ALAMODE_GRANTS and the hosts in ALAMODE_ALLOWED_HOSTS
 * (warning), "local only" under --local (success), or "sandbox closed".
 * Without ALAMODE_AVAILABLE_GRANTS the wrapper did not run and the border
 * stays plain. --listen and path grants are not exported, so they never
 * appear.
 *
 * Right: the thinking level, naming the color pi already gives the border
 * (InteractiveMode sets editor.borderColor from getThinkingBorderColor).
 * In bash mode ("!") the border is bashMode and no model runs the command,
 * so the label says bash and the level is dropped.
 *
 * Set on session_start: /reload's resetExtensionUI() drops a custom editor.
 */

import {
  CustomEditor,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

const END = 3;

function names(value: string | undefined): string[] {
  return (value ?? "").split(",").filter((name) => name !== "");
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    if (!ctx.hasUI) return;
    const sandboxed = process.env.ALAMODE_AVAILABLE_GRANTS !== undefined;
    const grants = [
      ...names(process.env.ALAMODE_GRANTS),
      ...names(process.env.ALAMODE_ALLOWED_HOSTS),
    ];
    const local = process.env.ALAMODE_LOCAL === "1";

    const posture = (): string => {
      const { theme } = ctx.ui;
      if (!sandboxed) return "";
      const parts = [
        ...(local ? [theme.fg("success", "local only")] : []),
        ...grants.map((grant) => theme.fg("warning", grant)),
      ];
      return parts.length > 0
        ? parts.join(theme.fg("dim", " · "))
        : theme.fg("dim", "sandbox closed");
    };

    class PostureEditor extends CustomEditor {
      renderTopBorder(width: number, hiddenLineCount: number): string {
        if (hiddenLineCount > 0)
          return super.renderTopBorder(width, hiddenLineCount);
        const line = (text: string): string => this.borderColor(text);
        const bash = this.getText().trimStart().startsWith("!");
        const label = (text: string): string => (text ? ` ${text} ` : "");
        const right = label(
          bash || !ctx.model?.reasoning ? "" : line(pi.getThinkingLevel()),
        );
        const room = width - 2 * END - visibleWidth(right);
        const left = truncateToWidth(
          label(bash ? ctx.ui.theme.fg("bashMode", "bash") : posture()),
          Math.max(0, room - 3),
          "",
        );
        const fill = room - visibleWidth(left);
        if (fill < 0) return super.renderTopBorder(width, hiddenLineCount);
        return (
          line("─".repeat(END)) +
          left +
          line("─".repeat(fill)) +
          right +
          line("─".repeat(END))
        );
      }
    }

    ctx.ui.setEditorComponent(
      (tui, theme, keybindings) => new PostureEditor(tui, theme, keybindings),
    );
  });
}
