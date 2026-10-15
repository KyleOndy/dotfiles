/**
 * regrant: the sandbox is fixed for the life of a pi process, so /regrant
 * writes the grant flags to ALAMODE_REGRANT_REQUEST and quits. The wrapper
 * asks at the terminal and starts pi again on the same transcript and
 * worktree (confirm_regrant in nix/pkgs/alamode-runtime/session.py).
 *
 * Without flags it opens a checklist of ALAMODE_GRANT_MENU, which
 * grant_menu() in session.py builds from the session's policy, so this
 * file holds no grant names or flag rules of its own. A row switches by the
 * tokens the menu gives it, and a locked row says why it cannot. Grants
 * that take a value (hosts, paths, ports) are edited as flags. A manifest
 * from before grant_args has no menu and goes straight to the editor.
 *
 * pi 1.1.0 writes "To resume this session: pi --session ..." after
 * session_shutdown. That pi is not on PATH, and run directly it would skip
 * the sandbox, so the line is dropped.
 */

import { writeFileSync } from "node:fs";
import type {
  ExtensionAPI,
  ExtensionCommandContext,
} from "@earendil-works/pi-coding-agent";
import {
  Container,
  type SettingItem,
  SettingsList,
} from "@earendil-works/pi-tui";

const PI_RESUME_LINE = "To resume this session:";

interface Row {
  name: string;
  flag: string;
  held: boolean;
  drop: string[];
  add: string[];
  /** Why the row cannot switch, or null when it can. */
  locked: string | null;
}

export interface Menu {
  args: string[];
  rows: Row[];
}

/** shlex.quote's rule, so the wrapper's shlex.split reads the args back. */
export function quote(args: string[]): string {
  return args
    .map((arg) =>
      /^[\w@%+=:,./-]+$/.test(arg) ? arg : `'${arg.replaceAll("'", `'"'"'`)}'`,
    )
    .join(" ");
}

/** The menu's args with each row WANTED in the other state switched. */
export function switched(
  menu: Menu,
  wanted: Record<string, boolean>,
): string[] {
  const rows = menu.rows.filter(
    (row) => !row.locked && (wanted[row.name] ?? row.held) !== row.held,
  );
  const drop = new Set(rows.flatMap((row) => row.drop));
  const args = menu.args.filter((arg) => !drop.has(arg));
  for (const arg of rows.flatMap((row) => row.add)) {
    if (!args.includes(arg)) args.push(arg);
  }
  return args;
}

function grantMenu(): Menu | undefined {
  try {
    return JSON.parse(process.env.ALAMODE_GRANT_MENU ?? "");
  } catch {
    return undefined;
  }
}

const RELAUNCH = "\0relaunch";
const EDIT = "\0edit";

/** "relaunch" or "edit" once chosen, with WANTED holding each switch made. */
function checklist(
  ctx: ExtensionCommandContext,
  menu: Menu,
  wanted: Record<string, boolean>,
): Promise<"relaunch" | "edit" | undefined> {
  return ctx.ui.custom((tui, theme, _keybindings, done) => {
    const state = (on: boolean) => (on ? "on" : "off");
    const items: SettingItem[] = [
      ...menu.rows.map((row) =>
        row.locked
          ? {
              id: row.name,
              label: row.flag,
              currentValue: `${state(row.held)}, locked`,
              description: row.locked,
            }
          : {
              id: row.name,
              label: row.flag,
              currentValue: state(row.held),
              values: ["on", "off"],
            },
      ),
      {
        id: RELAUNCH,
        label: "Relaunch with these grants",
        currentValue: "",
        values: [""],
      },
      { id: EDIT, label: "Edit them as flags", currentValue: "", values: [""] },
    ];
    // getSettingsListTheme()'s styling, from the theme handed in: the
    // global one it reads throws "Theme not initialized" outside the TUI.
    const list = new SettingsList(
      items,
      Math.min(items.length, 15),
      {
        label: (text, selected) => (selected ? theme.fg("accent", text) : text),
        value: (text, selected) =>
          theme.fg(selected ? "accent" : "muted", text),
        description: (text) => theme.fg("dim", text),
        cursor: theme.fg("accent", "→ "),
        hint: (text) => theme.fg("dim", text),
      },
      (id, value) => {
        if (id === RELAUNCH) done("relaunch");
        else if (id === EDIT) done("edit");
        else wanted[id] = value === "on";
      },
      () => done(undefined),
    );
    const container = new Container();
    container.addChild({
      render: () => [theme.fg("accent", theme.bold("Grants")), ""],
      invalidate() {},
    });
    container.addChild(list);
    return {
      render: (width: number) => container.render(width),
      invalidate: () => container.invalidate(),
      handleInput(data: string) {
        list.handleInput(data);
        tui.requestRender();
      },
    };
  });
}

/** The flags to relaunch with, or undefined to keep the session running. */
async function choose(
  ctx: ExtensionCommandContext,
): Promise<string | undefined> {
  let flags = process.env.ALAMODE_GRANT_ARGS ?? "";
  const menu = grantMenu();
  if (menu && ctx.mode === "tui") {
    const wanted: Record<string, boolean> = {};
    const choice = await checklist(ctx, menu, wanted);
    if (choice === undefined) return undefined;
    flags = quote(switched(menu, wanted));
    if (choice === "relaunch") {
      if (flags !== quote(menu.args)) return flags;
      ctx.ui.notify("No grant changed, so the session carries on.", "info");
      return undefined;
    }
  }
  const edited = await ctx.ui.editor(
    "Grant flags, in place of this session's own",
    flags,
  );
  return edited?.trim();
}

function dropPiResumeLine() {
  const write = process.stdout.write.bind(process.stdout);
  process.stdout.write = ((chunk: any, ...rest: any[]) =>
    String(chunk).includes(PI_RESUME_LINE)
      ? true
      : write(chunk, ...rest)) as typeof process.stdout.write;
}

export default function (pi: ExtensionAPI) {
  pi.registerCommand("regrant", {
    description: "Relaunch this session with different grants",
    handler: async (args, ctx) => {
      const request = process.env.ALAMODE_REGRANT_REQUEST;
      if (!request) {
        ctx.ui.notify(
          "A coordinator and its agents keep their grants; start a new coordinator to change them.",
          "error",
        );
        return;
      }
      const flags = args.trim() || (await choose(ctx));
      if (flags === undefined) return;
      writeFileSync(request, flags + "\n", { mode: 0o600 });
      // wip-on-exit.ts reads it: the relaunch keeps the worktree as it is.
      process.env.ALAMODE_REGRANTING = "1";
      ctx.shutdown();
    },
  });

  pi.on("session_shutdown", (event, ctx) => {
    const id = process.env.ALAMODE_SESSION_ID;
    if (event.reason !== "quit" || !id) return;
    dropPiResumeLine();
    if (!ctx.hasUI || !process.stdout.isTTY) return;
    if (process.env.ALAMODE_REGRANTING) return;
    if (process.env.ALAMODE_COORD_ROLE === "child") return;
    if (!/^[A-Za-z0-9_-]+$/.test(id)) return;
    const grants = process.env.ALAMODE_GRANT_ARGS || "GRANTS";
    process.stdout.write(
      `\x1b[2mTo resume with its grants:\x1b[22m alamode resume ${id}\n` +
        `\x1b[2mTo change its grants:\x1b[22m      alamode resume ${id} ${grants}\n`,
    );
  });
}
