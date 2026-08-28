/**
 * terminal-title: put the agent's state in the terminal title.
 *
 * Pi already titles the terminal `π - session - cwd` and keeps it current
 * (InteractiveMode.updateTerminalTitle), so the state is the only bit
 * missing. No getter exposes that string, so the format is rebuilt here to
 * prefix it.
 *
 * A marker, not a spinner: the working row already animates on screen, and
 * a title spinner writes an OSC escape per frame for what one glyph says.
 * Both states are drawn so the marker column never shifts the rest.
 *
 * tmux sets `allow-rename off` (terminal/tmux.nix), which confines every
 * OSC title under tmux to #{pane_title}. Visible in Alacritty's title bar
 * outside tmux; inside it, only where a tmux format reads pane_title.
 *
 * terminal/tmux-agent-icons.sh is such a format, rendering the state in the
 * window tab beside Claude Code's `cc:` icons. Under tmux the title is
 * therefore parsed rather than read, and carries a `[pi:RUN]` token in
 * place of the glyph. It is the only channel that reaches tmux from inside
 * the sandbox: the pane option Claude Code's hooks write needs the tmux
 * socket, which srt denies, and granting it would also hand the agent
 * `tmux new-window` and `send-keys`, which execute outside the sandbox.
 *
 * States are IDL waiting on you, RUN in the agent loop, EXE running a tool,
 * CMP compacting, and RTY sleeping between provider retries, which the
 * retry budget stretches to 126s. There is no permission-prompt state: pi
 * gates tools with the sandbox rather than by asking. `--print` and
 * `--mode json` leave hasUI false, where setTitle is a no-op, so a
 * non-interactive run reports nothing.
 *
 * Applied on session_start rather than once at load: /reload runs
 * resetExtensionUI(), whose updateTerminalTitle() call drops the marker.
 *
 * A session shows no state until its first prompt, and that is deliberate.
 * InteractiveMode writes the title once more at the end of its bind path,
 * after an await and so after every extension has seen session_start, and
 * the only ways to win that would be a timer racing an await or a
 * foreground-process check in the tab script. The same write on the way out
 * is what clears the token from a pane the agent has left, so a tab that
 * says nothing is right more often than one that guesses.
 */

import path from "node:path";
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";

// tmux sets this in every pane. TMUX itself is blanked inside the sandbox so
// pi skips its keyboard probe (see the pi-coding-agent module), which leaves
// this as the only marker that a tmux format is reading the title.
const underTmux = Boolean(process.env.TMUX_PANE);

export default function (pi: ExtensionAPI) {
  // null while pi is shutting down, so a pane the agent has left behind
  // stops claiming a state it is no longer in.
  let state: string | null = "IDL";

  const show = (ctx: ExtensionContext): void => {
    if (!ctx.hasUI) return;
    const name = pi.getSessionName();
    const cwd = path.basename(ctx.cwd);
    // Shutdown drops pi's prefix along with the state: the title outlives the
    // process that wrote it, and pi is no longer what this pane is running.
    if (state === null) {
      ctx.ui.setTitle(cwd);
      return;
    }
    const title = `π - ${name ? `${name} - ${cwd}` : cwd}`;
    const marker = underTmux ? `[pi:${state}]` : state === "IDL" ? "○" : "●";
    ctx.ui.setTitle(`${marker} ${title}`);
  };

  const enter = (next: string | null, ctx: ExtensionContext): void => {
    state = next;
    show(ctx);
  };

  pi.on("session_start", (_event, ctx) => enter("IDL", ctx));
  pi.on("session_info_changed", (_event, ctx) => show(ctx));
  pi.on("session_shutdown", (_event, ctx) => enter(null, ctx));

  pi.on("agent_start", (_event, ctx) => enter("RUN", ctx));
  pi.on("agent_settled", (_event, ctx) => enter("IDL", ctx));
  pi.on("tool_execution_start", (_event, ctx) => enter("EXE", ctx));
  pi.on("tool_execution_end", (_event, ctx) => enter("RUN", ctx));
  pi.on("session_before_compact", (_event, ctx) => enter("CMP", ctx));
  pi.on("session_compact", (_event, ctx) => enter("RUN", ctx));

  // Retries sleep without any other event firing, so a pane in RUN can be
  // waiting on a backoff rather than on the model.
  pi.on("after_provider_response", (event, ctx) => {
    if (event.status >= 400) enter("RTY", ctx);
  });
}
