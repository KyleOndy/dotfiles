// Pi Extension: Mode Guard
// Provides /mode command to switch between research, code, plan, act modes
// Provides /plan command to auto-create timestamped plan files

import * as fs from "fs";
import * as path from "path";

export default function (pi: any) {
  // Track current mode
  let currentMode: "research" | "code" | "plan" | "act" = "code";

  // Register /mode command
  pi.registerCommand("mode", {
    description: "Switch modes: /mode research|code|plan|act",
    handler: (args: string) => {
      const mode = (args.trim() as typeof currentMode) || "code";

      if (!["research", "code", "plan", "act"].includes(mode)) {
        return `Unknown mode: ${mode}. Use: research, code, plan, or act`;
      }

      currentMode = mode;

      // Return mode-specific guidance
      const guidance: Record<string, string> = {
        research:
          "Research mode: read-only. Ask before any file modifications.",
        code: "Code mode: full tool access. Make changes as needed.",
        plan: "Plan mode: write plan files first. Wait for approval before executing.",
        act: "Act mode: execute from existing plan. Update todo.md as you go.",
      };

      return `${guidance[mode]}\n\nCurrent mode: ${currentMode}`;
    },
  });

  // Gate tool calls based on mode
  pi.on("tool_call", async (event: any, ctx: any) => {
    const writeTools = ["write_file", "edit_file", "delete_file"];

    if (currentMode === "research" && writeTools.includes(event.tool)) {
      ctx.preventDefault();
      return ctx.error(
        `Research mode active. Write/edit tools blocked.\n` +
          `Use "/mode code" to enable modifications, or describe what you'd like to change.`,
      );
    }

    if (currentMode === "plan" && writeTools.includes(event.tool)) {
      const filePath = event.args.path || event.args.file || "";
      const name = path.basename(filePath);

      // Allow plan workflow files: plans/ dir, todo, status, notes, conventions
      const isPlanWorkflow =
        filePath.includes("/plans/") ||
        name === "todo.md" ||
        name === "status.md" ||
        name.endsWith("-status.md") ||
        name.endsWith("-claudes-notes.md") ||
        ["AGENTS.md", "CLAUDE.md", "README.md"].includes(name);

      if (!isPlanWorkflow) {
        ctx.preventDefault();
        return ctx.error(
          `Plan mode: can only write to plan workflow files (plans/, todo.md, status.md, etc.)\n` +
            `Currently trying to modify: ${filePath}\n` +
            `Use "/mode act" to execute the plan, or "/mode code" for free-form editing.`,
        );
      }
    }
  });

  // Register /plan command - automatically creates timestamped plan file
  pi.registerCommand("plan", {
    description: "Create new plan file: /plan <meaningful-name>",
    handler: (args: string) => {
      if (!args.trim()) {
        return "Plan name required. Usage: /plan <meaningful-name>\nExample: /plan refactor-auth-endpoint";
      }

      const name = args.trim();
      const now = new Date();
      const timestamp = now.toISOString().slice(0, 16).replace(/:/g, "-"); // YYYY-MM-DD-HH-MM
      const filename = `${timestamp}-${name.toLowerCase().replace(/\s+/g, "-")}.md`;

      // Determine plans directory (cwd/plans/)
      const cwd = process.cwd();
      const plansDir = path.join(cwd, "plans");
      const filepath = path.join(plansDir, filename);

      // Create plans directory if it doesn't exist
      if (!fs.existsSync(plansDir)) {
        fs.mkdirSync(plansDir, { recursive: true });
      }

      const template = `# Plan: [One sentence goal]

**Created:** ${now.toISOString().replace("T", " ").slice(0, 16)}
**Approach:** ${name}
**Timebox:** [estimated duration]

<!-- Fill in sections per the plan-act skill template:
     Goal, Success Criteria, Background, Assumptions,
     Risks & Mitigations, Task Breakdown, Stop Conditions,
     Next Plan, Notes -->
`;

      // Write the file
      fs.writeFileSync(filepath, template, "utf-8");

      // Build relative path from cwd for display
      const relativePath = path.relative(cwd, filepath);

      return `Plan file created: ${relativePath}

What to do next:
1. Read it: read {"file": "${relativePath}"}
2. Fill in the sections (see plan-act skill for template)
3. Switch to plan mode: /mode plan
4. When ready to execute: /mode act`;
    },
  });

  // Show mode on startup notification
  pi.on("startup", () => {
    pi.notify?.(
      `Mode guard loaded. Current: ${currentMode}. Use /mode to switch.`,
    );
  });
}
