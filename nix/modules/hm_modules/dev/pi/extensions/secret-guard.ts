/**
 * secret-guard — in-process secret-read guard for the pi coding agent.
 *
 * Companion to the OS-level srt wrapper (nix/pkgs/pi-wrapper). That wrapper
 * default-denies reads across $HOME but must re-allow $PWD so the agent can
 * read the code it's working on. srt's allowRead beats denyRead, so it cannot
 * carve a deny hole inside $PWD — a repo-local .env / *.pem / *.key stays
 * readable. This extension closes that gap from inside pi: it intercepts the
 * read/edit/write/grep/find/ls tool calls and blocks any that target a
 * secret-looking path, then logs every block as JSONL for tuning.
 *
 * Scope and limits (deliberately honest):
 *   - Reliable for the structured tools (read/edit/write/grep/find/ls): the
 *     target path is an explicit argument, so matching is exact.
 *   - bash is best-effort: the command is tokenised and blocked if a token
 *     names a secret path (catches `cat .env`), but obfuscated reads
 *     (python open(), base64, here-docs) slip through. The OS sandbox is the
 *     real boundary for bash; this is defence-in-depth.
 *   - grep/find over a directory that *contains* a secret can still surface its
 *     contents; we only block when the explicit path arg is a secret file.
 *     Treat in-repo secrets as "keep them out of the tree", not "fully
 *     contained".
 *
 * Config (optional, merged: defaults <- global <- project):
 *   ~/.pi/agent/secret-guard.json   and   <cwd>/.pi/secret-guard.json
 *   { "enabled": true, "scanBash": true,
 *     "denyPatterns": ["*.pem", ...], "allowPatterns": [".env.example", ...] }
 * Disable for one run with --no-secret-guard.
 */

import {
  appendFileSync,
  existsSync,
  readFileSync,
  renameSync,
  statSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, isAbsolute, join, resolve } from "node:path";
import type {
  ExtensionAPI,
  ToolCallEvent,
} from "@earendil-works/pi-coding-agent";

interface SecretGuardConfig {
  enabled: boolean;
  scanBash: boolean;
  denyPatterns: string[];
  allowPatterns: string[];
}

const DEFAULT_CONFIG: SecretGuardConfig = {
  enabled: true,
  scanBash: true,
  // Basename globs. High-signal secret material, not general config — the agent
  // rarely needs to read these, so blocking them has a low false-positive rate.
  denyPatterns: [
    ".env",
    ".env.*",
    "*.pem",
    "*.key",
    "*.p12",
    "*.pfx",
    "*.jks",
    "*.keystore",
    "id_rsa",
    "id_dsa",
    "id_ecdsa",
    "id_ed25519",
    "*.secret",
    "credentials.json",
  ],
  // Committed, non-secret templates that .env.* would otherwise catch.
  allowPatterns: [
    ".env.example",
    ".env.sample",
    ".env.template",
    ".env.dist",
    ".env.defaults",
  ],
};

function agentDir(): string {
  return process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent");
}

// Minimal basename glob: * -> any run of non-slash chars, ? -> one, rest literal.
function globToRegExp(glob: string): RegExp {
  let re = "";
  for (const ch of glob) {
    if (ch === "*") re += "[^/]*";
    else if (ch === "?") re += "[^/]";
    else re += ch.replace(/[.+^${}()|[\]\\]/g, "\\$&");
  }
  return new RegExp(`^${re}$`);
}

function loadConfig(cwd: string): SecretGuardConfig {
  const merge = (base: SecretGuardConfig, path: string): SecretGuardConfig => {
    if (!existsSync(path)) return base;
    try {
      const o = JSON.parse(
        readFileSync(path, "utf-8"),
      ) as Partial<SecretGuardConfig>;
      return {
        enabled: o.enabled ?? base.enabled,
        scanBash: o.scanBash ?? base.scanBash,
        denyPatterns: o.denyPatterns ?? base.denyPatterns,
        allowPatterns: o.allowPatterns ?? base.allowPatterns,
      };
    } catch (e) {
      console.error(`secret-guard: could not parse ${path}: ${e}`);
      return base;
    }
  };
  let cfg = DEFAULT_CONFIG;
  cfg = merge(cfg, join(agentDir(), "secret-guard.json"));
  cfg = merge(cfg, join(cwd, ".pi", "secret-guard.json"));
  return cfg;
}

// Returns the matched deny pattern, or null if the basename is not a secret.
function matchSecret(path: string, cfg: SecretGuardConfig): string | null {
  const name = basename(path);
  if (!name) return null;
  if (cfg.allowPatterns.some((p) => globToRegExp(p).test(name))) return null;
  for (const p of cfg.denyPatterns) {
    if (globToRegExp(p).test(name)) return p;
  }
  return null;
}

// Crude shell split for the bash best-effort scan — good enough to catch direct
// references like `cat .env`, not a real parser.
function bashTokens(command: string): string[] {
  return command
    .split(/[\s;|&<>()`"'=]+/)
    .map((t) => t.trim())
    .filter(Boolean);
}

export default function (pi: ExtensionAPI) {
  pi.registerFlag("no-secret-guard", {
    description: "Disable the in-process secret-read guard for this run",
    type: "boolean",
    default: false,
  });

  let cfg = DEFAULT_CONFIG;
  let active = true;

  const logViolation = (entry: Record<string, unknown>): void => {
    try {
      const file = join(agentDir(), "secret-guard-violations.log");
      try {
        if (statSync(file).size > 5 * 1024 * 1024)
          renameSync(file, `${file}.1`);
      } catch {
        // no existing log yet — nothing to rotate
      }
      appendFileSync(
        file,
        `${JSON.stringify({ ts: new Date().toISOString(), ...entry })}\n`,
      );
    } catch {
      // logging must never break a tool call
    }
  };

  // Explicit path argument for the structured tools.
  const candidatePath = (event: ToolCallEvent): string | undefined => {
    switch (event.toolName) {
      case "read":
      case "edit":
      case "write":
      case "grep":
      case "find":
      case "ls": {
        const p = (event.input as Record<string, unknown>).path;
        return typeof p === "string" ? p : undefined;
      }
      default:
        return undefined;
    }
  };

  pi.on("tool_call", (event, ctx) => {
    if (!active) return;
    const cwd = ctx.cwd ?? process.cwd();
    const abs = (p: string): string => (isAbsolute(p) ? p : resolve(cwd, p));

    const p = candidatePath(event);
    if (p !== undefined) {
      const pattern = matchSecret(p, cfg);
      if (pattern) {
        logViolation({ tool: event.toolName, path: abs(p), pattern, cwd });
        return {
          block: true,
          reason:
            `secret-guard: blocked ${event.toolName} of "${basename(p)}" (matches ${pattern}). ` +
            `Secrets in the working tree are off-limits to the agent; resolve them via env/Keychain instead.`,
        };
      }
    }

    if (event.toolName === "bash" && cfg.scanBash) {
      const command = (event.input as Record<string, unknown>).command;
      if (typeof command === "string") {
        for (const tok of bashTokens(command)) {
          const pattern = matchSecret(tok, cfg);
          if (pattern) {
            logViolation({ tool: "bash", token: tok, pattern, cwd, command });
            return {
              block: true,
              reason:
                `secret-guard: blocked bash command referencing "${basename(tok)}" (matches ${pattern}). ` +
                `If this is a false positive, narrow denyPatterns in .pi/secret-guard.json.`,
            };
          }
        }
      }
    }
  });

  pi.on("session_start", (_event, ctx) => {
    if (pi.getFlag("no-secret-guard") === true) {
      active = false;
      if (ctx.hasUI)
        ctx.ui.notify("secret-guard disabled via --no-secret-guard", "warning");
      return;
    }
    cfg = loadConfig(ctx.cwd);
    active = cfg.enabled;
    if (ctx.hasUI && active) {
      ctx.ui.setStatus(
        "secret-guard",
        ctx.ui.theme.fg("accent", "secret-guard"),
      );
    }
  });

  pi.registerCommand("secret-guard", {
    description: "Show the secret-read guard configuration",
    handler: (_args, ctx) => {
      const lines = [
        `secret-guard: ${active ? "active" : "disabled"}`,
        `bash scan: ${cfg.scanBash ? "on" : "off"}`,
        `deny: ${cfg.denyPatterns.join(", ")}`,
        `allow: ${cfg.allowPatterns.join(", ")}`,
        `log: ${join(agentDir(), "secret-guard-violations.log")}`,
      ];
      ctx.ui.notify(lines.join("\n"), "info");
    },
  });

  pi.registerCommand("secret-guard-log", {
    description: "Show recent secret-guard blocks",
    handler: (_args, ctx) => {
      const file = join(agentDir(), "secret-guard-violations.log");
      if (!existsSync(file)) {
        ctx.ui.notify("secret-guard: no violations logged", "info");
        return;
      }
      const recent = readFileSync(file, "utf-8").trim().split("\n").slice(-20);
      ctx.ui.notify(
        ["recent secret-guard blocks:", ...recent].join("\n"),
        "info",
      );
    },
  });
}
