/**
 * refusal-guard: name the sandbox at the moment it refuses.
 *
 * grants.ts writes the missing-grants menu into the system prompt at start,
 * which is prevention. This is the moment of failure: a bash command comes
 * back with the text an OS-level refusal produces, and the model is left to
 * guess whether it hit a bug, a permissions mistake of its own, or the
 * sandbox. Guessing produced workarounds before this existed. This appends a
 * short note to the failed bash result that identifies a possible refusal, lists the
 * grants this session does not carry, and restates the protocol: name the
 * --allow-<name> flag, ask the human to restart, do not retry or work
 * around.
 *
 * Signatures are the strings srt's policy actually produced on this setup,
 * measured, not guessed:
 *   - "Operation not permitted": EPERM from seatbelt/bwrap for filesystem
 *     writes outside allowWrite, unix-socket connects, and local binds.
 *   - "Error connecting to agent": ssh-add against an ungranted agent socket.
 *   - "Failed to connect to 127.0.0.1 port": egress through srt's proxy when
 *     the allowlist has no entry (or nothing is granted) presents as a TCP
 *     connect failure to the loopback proxy port.
 * Not signatures, deliberately:
 *   - crashpad's "bootstrap_check_in ... Permission denied": nix prints it
 *     even when the operation succeeds (nix store ping measured), so it
 *     says nothing about the sandbox.
 *   - anything secret-guard emitted: that block already carries its own
 *     guidance, and the refusal in it is in-process, not the OS sandbox.
 *
 * A refusal is a hint about the session, not about the command, so each
 * signature is named at most once per session and the whole extension stops
 * after three: past that the model has the pattern and more copies are
 * context bloat, not information.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// crashpad noise to drop before matching: nix's crash reporter dies on the
// sandbox even when the nix operation itself succeeds.
const CRASHPAD = /^\[[^\]]*(bootstrap\.cc|child_port_handshake)[^\]]*\].*$/gm;

const SIGNATURES: { re: RegExp; name: string }[] = [
  { re: /Operation not permitted/, name: "fs-write-or-socket-denied" },
  { re: /Error connecting to agent/, name: "ssh-agent-socket-denied" },
  { re: /Failed to connect to 127\.0\.0\.1 port \d+/, name: "egress-denied" },
];

function splitNames(value: string | undefined): string[] {
  return (value ?? "").split(",").filter((name) => name !== "");
}

const MAX_NUDGES = 3;

export default function (pi: ExtensionAPI) {
  const seen = new Set<string>();
  let nudges = 0;

  pi.on("tool_result", (event, ctx) => {
    if (event.toolName !== "bash" || !event.isError) return;
    const blocks = event.content ?? [];
    const text = blocks
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("\n");

    // In-process guards carry their own guidance; never name the OS sandbox
    // for a refusal that was not one.
    if (text.includes("secret-guard:") || text.includes("refusal-guard:"))
      return;

    const quiet = text.replace(CRASHPAD, "");
    const hit = SIGNATURES.find(
      (sig) => !seen.has(sig.name) && sig.re.test(quiet),
    );
    if (!hit || nudges >= MAX_NUDGES) return;

    seen.add(hit.name);
    nudges++;

    const carried = splitNames(process.env.PI_GRANTS);
    const missing = splitNames(process.env.PI_AVAILABLE_GRANTS).filter(
      (name) => !carried.includes(name),
    );
    const catalog =
      missing.length > 0
        ? `Grants this session does not carry: ${missing.join(", ")}.`
        : "This session carries every grant the wrapper knows; the block is a policy deny, not a missing flag.";

    const note =
      `[refusal-guard] The line above looks like the OS sandbox refusing (signature: ` +
      `${hit.name}). It may also be an ordinary permission or connection error. ${catalog} ` +
      `Check the failed operation against this session's grants. If a grant is missing, ` +
      `name the --allow-<name> flag and ask the human to restart pi with it; ` +
      `the sandbox cannot widen mid-session. Do not work around a policy denial.`;

    blocks.push({ type: "text", text: note });

    if (ctx.hasUI)
      ctx.ui.setStatus("refusal-guard", `refusal-guard: ${nudges} refusal(s)`);
  });
}
