import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";

export default function (pi: any) {
  pi.registerProvider("synthetic", {
    api: "synthetic-rpc-test",
    baseUrl: "https://synthetic.invalid",
    apiKey: "synthetic-nonsecret",
    models: [
      {
        id: "fixture",
        name: "Fixture",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 32000,
        maxTokens: 1000,
      },
    ],
    streamSimple(model: any, context: any, options: any) {
      const stream = createAssistantMessageEventStream();
      const users = context.messages.filter((m: any) => m.role === "user");
      const latest = users.at(-1)?.content;
      const text =
        typeof latest === "string"
          ? latest
          : (latest ?? [])
              .filter((p: any) => p.type === "text")
              .map((p: any) => p.text)
              .join("");
      const result: any = {
        role: "assistant",
        api: model.api,
        provider: model.provider,
        model: model.id,
        timestamp: Date.now(),
        stopReason: "pending",
        content: [],
        usage: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
      };
      const timer = setTimeout(
        () => {
          if (result.stopReason !== "pending") return;
          result.stopReason = text.includes("FAIL_FIXTURE") ? "error" : "stop";
          if (result.stopReason === "error") {
            result.errorMessage = "Synthetic provider failure";
            stream.push({ type: "error", reason: "error", error: result });
          } else {
            result.content = text.includes("EMPTY_FIXTURE")
              ? []
              : [{ type: "text", text: `reply:${text};users=${users.length}` }];
            stream.push({ type: "done", reason: "stop", message: result });
          }
          stream.end();
        },
        text.includes("SLOW_FIXTURE") ? 1200 : 30,
      );
      const cancel = () => {
        if (result.stopReason !== "pending") return;
        clearTimeout(timer);
        result.stopReason = "aborted";
        result.errorMessage = "Synthetic cancelled";
        stream.push({ type: "error", reason: "aborted", error: result });
        stream.end();
      };
      if (options?.signal?.aborted) cancel();
      else options?.signal?.addEventListener("abort", cancel, { once: true });
      return stream;
    },
  });
  pi.registerCommand("fixture-question", {
    description: "Synthetic dialog",
    async handler(_args: string, ctx: any) {
      const answer = await ctx.ui.input("Synthetic child question");
      ctx.ui.notify(`answer:${answer}`);
    },
  });
}
