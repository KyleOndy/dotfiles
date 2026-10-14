/**
 * tool-rows: each tool call as one row with a colored stripe for its state.
 *
 *   ▌ bash  make build-trex                              exit 2  41s
 *   ▌       error: attribute 'agentIcons' missing
 *
 * Yellow while pending or running, green done, red failed. A failure keeps
 * the last lines of its output under the row; ctrl+o expands any row to
 * the tool's own renderer, which the row delegates to.
 *
 * The rows need renderShell "self", which drops pi's tinted box and its
 * indent; the rows indent themselves by context.outputPad, so the stripe
 * lines up with message text. pi still puts one blank line above every
 * self-rendered call (ToolExecutionComponent.render), so rows cannot sit
 * flush.
 *
 * A tool renderer resolver wraps whatever read, edit, write and bash
 * already resolve to, so their definitions stay registered as they are,
 * stall-guard.ts's bash included.
 *
 * The call renderer draws the row until the result is final, then renders
 * nothing and the result renderer draws it: only the result knows the exit
 * code or the diff. context.state is shared by both for one call, and
 * holds when it started, for the running counter; the final time is the
 * one pi recorded, which survives a resume.
 */

import type {
  ExtensionAPI,
  Theme,
  ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import {
  Box,
  type Component,
  Container,
  truncateToWidth,
  visibleWidth,
} from "@earendil-works/pi-tui";
import path from "node:path";

export const NAME_CELLS = 6;
const TAIL_LINES = 2;

interface Timing {
  startedAt?: number;
}

interface Result {
  content: { type: string; text?: string }[];
  details?: unknown;
}

export interface RowSpec<Args> {
  summary(args: Partial<Args>, cwd: string, theme: Theme): string;
  // Right-aligned text for a final result. took is undefined under a
  // second, or when the tool never ran.
  meta(
    result: Result,
    args: Partial<Args>,
    failed: boolean,
    took: string | undefined,
    theme: Theme,
  ): string;
  // Output lines worth keeping under a failed row; defaults to the text.
  tail?(text: string): string[];
}

export const EMPTY: Component = { render: () => [], invalidate() {} };

export class Lines implements Component {
  constructor(private readonly draw: (width: number) => string[]) {}
  render(width: number): string[] {
    return this.draw(width);
  }
  invalidate(): void {}
}

export function indent(component: Component, cells: number): Component {
  if (cells <= 0) return component;
  const box = new Box(cells, 0);
  box.addChild(component);
  return box;
}

export function elapsed(ms: number): string {
  if (ms < 10_000) return `${(ms / 1000).toFixed(1)}s`;
  const total = Math.round(ms / 1000);
  if (total < 60) return `${total}s`;
  return `${Math.floor(total / 60)}m${String(total % 60).padStart(2, "0")}s`;
}

export function relative(file: string | undefined, cwd: string): string {
  if (!file) return "";
  const inside = path.relative(cwd, path.resolve(cwd, file));
  return inside.startsWith("..") || path.isAbsolute(inside) ? file : inside;
}

export function text(result: Result): string {
  return result.content
    .map((part) => (part.type === "text" ? (part.text ?? "") : ""))
    .join("\n");
}

export function row(
  theme: Theme,
  stripe: string,
  name: string,
  summary: string,
  meta: string,
  width: number,
): string {
  const left = `${theme.fg(stripe, "▌")} ${theme.fg("muted", name.padEnd(NAME_CELLS))}${summary}`;
  const room = width - visibleWidth(meta) - 2;
  if (!meta || room < 12) return truncateToWidth(left, width, "...");
  const fitted = truncateToWidth(left, room, "...");
  return (
    fitted +
    " ".repeat(width - visibleWidth(fitted) - visibleWidth(meta)) +
    meta
  );
}

// A line under a row, behind the same stripe and starting where the row's
// summary does.
export function continuation(
  theme: Theme,
  stripe: string,
  text: string,
  width: number,
): string {
  return truncateToWidth(
    `${theme.fg(stripe, "▌")}${" ".repeat(NAME_CELLS + 1)}${text}`,
    width,
    "...",
  );
}

export function rows<Args>(
  name: string,
  base: ToolDefinition,
  spec: RowSpec<Args>,
): Pick<ToolDefinition, "renderShell" | "renderCall" | "renderResult"> {
  return {
    renderShell: "self",

    renderCall(args, theme, context) {
      const timing = context.state as Timing;
      if (context.executionStarted) timing.startedAt ??= Date.now();
      if (!context.isPartial) return EMPTY;
      return indent(
        new Lines((width) => [
          row(
            theme,
            "warning",
            name,
            spec.summary(args as Partial<Args>, context.cwd, theme),
            timing.startedAt === undefined
              ? ""
              : theme.fg(
                  "warning",
                  `running ${elapsed(Date.now() - timing.startedAt)}`,
                ),
            width,
          ),
        ]),
        context.outputPad,
      );
    },

    renderResult(result, options, theme, context) {
      if (options.isPartial) return EMPTY;
      const pad = (component: Component): Component =>
        indent(component, context.outputPad);
      const ms = context.durationMs ?? 0;
      const took = ms < 1000 ? undefined : elapsed(ms);
      const failed = context.isError;
      const args = context.args as Partial<Args>;
      const head = new Lines((width) => [
        row(
          theme,
          failed ? "error" : "success",
          name,
          spec.summary(args, context.cwd, theme),
          spec.meta(result, args, failed, took, theme),
          width,
        ),
      ]);

      if (options.expanded && base.renderResult) {
        const full = new Container();
        full.addChild(head);
        full.addChild(
          base.renderResult(result, options, theme, {
            ...context,
            lastComponent: undefined,
          }),
        );
        return pad(full);
      }
      if (!failed) return pad(head);

      const output = text(result);
      const tail = (spec.tail?.(output) ?? output.split("\n"))
        .filter((line) => line.trim() !== "")
        .slice(-TAIL_LINES);
      return pad(
        new Lines((width) => [
          ...head.render(width),
          ...tail.map((line) =>
            continuation(theme, "error", theme.fg("toolOutput", line), width),
          ),
        ]),
      );
    },
  };
}

// pi's bash appends "Command exited with code N" to a failing call's
// output (createBashToolDefinition's execute), and isError is all the
// renderer gets besides the text.
const EXIT = /\n*Command exited with code (\d+)\s*$/;

function lineCount(content: string): string {
  const lines = content === "" ? 0 : content.split("\n").length;
  const count = content.endsWith("\n") ? lines - 1 : lines;
  return `${count} ${count === 1 ? "line" : "lines"}`;
}

const SPECS: Record<string, RowSpec<any>> = {
  bash: {
    summary: (args) => (args.command ?? "").split("\n")[0],
    meta: (result, _args, failed, took, theme) => {
      const output = text(result);
      const code = EXIT.exec(output)?.[1];
      const status = failed
        ? theme.fg("error", code ? `exit ${code}` : "failed")
        : theme.fg("dim", lineCount(output));
      return took ? `${status}${theme.fg("dim", `  ${took}`)}` : status;
    },
    tail: (output) => output.replace(EXIT, "").split("\n"),
  },

  read: {
    summary: (args, cwd, theme) =>
      relative(args.path, cwd) +
      (args.offset || args.limit
        ? theme.fg(
            "dim",
            `:${args.offset ?? 1}${args.limit ? `+${args.limit}` : ""}`,
          )
        : ""),
    meta: (result, _args, failed, _took, theme) =>
      failed
        ? theme.fg("error", "failed")
        : result.content.some((part) => part.type === "image")
          ? theme.fg("dim", "image")
          : theme.fg("dim", lineCount(text(result))),
  },

  edit: {
    summary: (args, cwd, theme) =>
      relative(args.path, cwd) +
      ((args.edits?.length ?? 0) > 1
        ? theme.fg("dim", ` (${args.edits?.length} edits)`)
        : ""),
    meta: (result, _args, failed, _took, theme) => {
      if (failed) return theme.fg("error", "failed");
      const diff = (result.details as { diff?: string } | undefined)?.diff;
      if (!diff) return "";
      const lines = diff.split("\n");
      const added = lines.filter(
        (line) => line.startsWith("+") && !line.startsWith("+++"),
      ).length;
      const removed = lines.filter(
        (line) => line.startsWith("-") && !line.startsWith("---"),
      ).length;
      return `${theme.fg("success", `+${added}`)} ${theme.fg("error", `-${removed}`)}`;
    },
  },

  write: {
    summary: (args, cwd) => relative(args.path, cwd),
    meta: (_result, args, failed, _took, theme) =>
      failed
        ? theme.fg("error", "failed")
        : theme.fg("dim", lineCount(args.content ?? "")),
  },
};

export default function (pi: ExtensionAPI) {
  pi.registerToolRenderer((name, next) => {
    const base = next();
    const spec = SPECS[name];
    return base && spec ? { ...base, ...rows(name, base, spec) } : base;
  });
}
