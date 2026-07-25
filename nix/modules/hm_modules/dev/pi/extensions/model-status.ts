/**
 * model-status — a footer line that always names the actual active model.
 *
 * pi's built-in footer reads session.state.model directly (dist/modes/
 * interactive/components/footer.js), and in practice that's been observed
 * showing a stale model (reverted to the first entry in the local provider's
 * list) after a `--model`-scripted invocation finishes its initial turn and
 * goes idle -- e.g. search-mail (nix/pkgs/search-mail/search-mail.sh)
 * reusing the same fixed workdir across invocations. The exact internal
 * trigger wasn't pinned down (none of AgentSession's four state.model
 * assignment sites -- setModel/_cycleScopedModel/_cycleAvailableModel/
 * _refreshCurrentModelFromRegistry -- fire for an idle session that received
 * no further model-change request), so rather than patch a vendored
 * dependency, this adds a second, independently-tracked status line via the
 * same ctx.ui.setStatus() extension API advisor.ts already uses.
 *
 * Driven by the model_select event, which fires on every real model change
 * (initial --model application, interactive cycling, /model) regardless of
 * whatever the native footer line ends up displaying afterward.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function formatModel(
  model: { provider: string; id: string } | undefined,
): string {
  if (!model) return "model: (none)";
  return `model: ${model.provider}/${model.id}`;
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    if (ctx.hasUI) ctx.ui.setStatus("model-status", formatModel(ctx.model));
  });

  pi.on("model_select", (event, ctx) => {
    if (ctx.hasUI) ctx.ui.setStatus("model-status", formatModel(event.model));
  });
}
