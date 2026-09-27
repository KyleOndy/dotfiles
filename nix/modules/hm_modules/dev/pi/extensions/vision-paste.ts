/**
 * Hands images to agents/vision.md when the session model is text-only.
 * Attached images (pasted, dragged) are written to temp files and dropped from
 * the message; image paths typed or pasted as text are kept. Either way the
 * prompt gets a note naming the paths and the agent to read them with.
 * Mid-turn, a `read` of an image path and any image block a tool returns are
 * replaced by the same note, so a path that turns up while working is handled
 * like a pasted one.
 * pi's read tool loads only png/jpeg/gif/webp/bmp, so HEIC, AVIF and TIFF go
 * through vips (on PATH from nix/pkgs/pi-wrapper) to JPEG; a path vips cannot
 * convert is listed unchanged.
 */
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const IMAGE_EXT = String.raw`\.(?:png|jpe?g|gif|webp|bmp|heic|heif|avif|tiff?)`;
const IMAGE_PATH = new RegExp(String.raw`(?:~|\/)\S+${IMAGE_EXT}\b`, "gi");
const IMAGE_FILE = new RegExp(`${IMAGE_EXT}$`, "i");
const NEEDS_CONVERSION = /\.(?:heic|heif|avif|tiff?)$/i;

type ImageBlock = { data: string; mimeType: string };

function expandHome(path: string): string {
  return path.replace(/^~(?=\/)/, homedir());
}

function toJpeg(path: string, dir: string): string {
  if (!NEEDS_CONVERSION.test(path)) return path;
  const src = expandHome(path);
  const out = join(dir, `${basename(src)}.jpg`);
  try {
    execFileSync("vips", ["copy", src, out], { stdio: "ignore" });
    return out;
  } catch {
    return path;
  }
}

// Returns the paths vision should read: images written out, HEIC and friends
// converted.
function stage(paths: string[], images: ImageBlock[]): string[] {
  const dir = mkdtempSync(join(tmpdir(), "pi-vision-"));
  const all = [...paths];
  images.forEach((img, i) => {
    const path = join(dir, `${i + 1}.${img.mimeType.split("/")[1] ?? "png"}`);
    writeFileSync(path, Buffer.from(img.data, "base64"));
    all.push(path);
  });
  return all.map((p) => toJpeg(p, dir));
}

function note(paths: string[]): string {
  return [
    '[You cannot see images. To inspect these, call `task` with `agent: "vision"`',
    "and `tasks` as plain strings, one per image, each naming the path and a",
    "specific question:",
    ...paths.map((p) => `- ${p}`),
    "vision runs on a hosted model, so each image leaves this machine. Ask the",
    "human first when an image looks personal or private.",
    "]",
  ].join("\n");
}

export default function (pi: ExtensionAPI) {
  pi.on("input", async (event, ctx) => {
    if (event.source === "extension" || !ctx.model)
      return { action: "continue" };
    if (ctx.model.input?.includes("image")) return { action: "continue" };

    const found = [...new Set(event.text.match(IMAGE_PATH) ?? [])];
    if (found.length === 0 && !event.images?.length)
      return { action: "continue" };

    const paths = stage(found, event.images ?? []);
    return {
      action: "transform",
      text: `${event.text}\n\n${note(paths)}`,
      images: [],
    };
  });

  pi.on("tool_result", (event, ctx) => {
    if (!ctx.model || ctx.model.input?.includes("image")) return;

    const content = event.content ?? [];
    const images = content.filter((b) => b.type === "image") as ImageBlock[];
    const path = event.input?.path;
    const readsImage =
      event.toolName === "read" &&
      typeof path === "string" &&
      IMAGE_FILE.test(path);
    if (!readsImage && images.length === 0) return;

    // A read of an image carries nothing but the image and its mime line, or
    // for HEIC and friends, the undecodable bytes.
    if (readsImage)
      return {
        content: [
          {
            type: "text",
            text: note(stage([resolve(ctx.cwd, expandHome(path))], [])),
          },
        ],
        isError: false,
      };
    return {
      content: [
        ...content.filter((b) => b.type !== "image"),
        { type: "text", text: note(stage([], images)) },
      ],
    };
  });
}
