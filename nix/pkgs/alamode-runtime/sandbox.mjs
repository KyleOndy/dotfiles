import fs from "node:fs";
import net from "node:net";
import { spawn } from "node:child_process";
import { SandboxManager } from "@sandboxRuntime@";

const input = JSON.parse(fs.readFileSync(Number(process.argv[2]), "utf8"));
const quote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";
const replacePolicy = (source, pattern, replacement, count = 1) => {
  const parts = source.split(pattern);
  if (parts.length !== count + 1)
    throw new Error("Unsupported sandbox profile layout");
  return parts.join(replacement);
};
const publicHost = ({ host }) => {
  try {
    const canonical = new URL(`http://${host}`).hostname
      .replace(/^\[|\]$/g, "")
      .replace(/\.$/, "");
    return (
      !net.isIP(canonical) &&
      canonical !== "localhost" &&
      !canonical.endsWith(".localhost")
    );
  } catch {
    return false;
  }
};

let child;
try {
  await SandboxManager.initialize(
    input.sandbox,
    input.web ? publicHost : undefined,
  );
  let command = await SandboxManager.wrapWithSandbox(
    input.argv.map(quote).join(" "),
    input.shell,
  );
  if (process.platform === "darwin") {
    command = replacePolicy(
      command,
      '  (global-name "com.apple.securityd.xpc")',
      "",
    );
    command = replacePolicy(
      command,
      '(allow mach-lookup (global-name "com.apple.SecurityServer"))',
      "",
    );
    command = replacePolicy(
      command,
      /  \(sysctl-name(?:-prefix)? "kern\.proc[^"\n]*"\)/g,
      "",
      3,
    );
    command = replacePolicy(
      command,
      "(allow process-info* (target same-sandbox))",
      "(deny process-info*)\n(allow process-info* (target self))",
    );
    command = replacePolicy(command, "(allow ipc-posix-shm)", "");
    // SRT 0.0.78's allowLocalBinding opens every loopback service. Admit only
    // the session's relay and explicitly requested preview ports instead.
    const marker = "(allow process-exec)";
    const ports = input.localPorts.map((port) => {
      if (!Number.isInteger(port) || port < 1 || port > 65535)
        throw new Error("Invalid local port");
      return `(allow network-outbound (remote ip "localhost:${port}"))`;
    });
    for (const port of input.listenPorts) {
      if (!Number.isInteger(port) || port < 1 || port > 65535)
        throw new Error("Invalid listen port");
      ports.push(`(allow network-bind (local ip "localhost:${port}"))`);
      ports.push(`(allow network-inbound (local ip "localhost:${port}"))`);
    }
    command = replacePolicy(
      command,
      marker,
      [
        marker,
        '(deny process-exec (subpath "/Library/PrivilegedHelperTools"))',
        ...ports,
      ].join("\n"),
    );
  }
  child = spawn(input.shell, ["-c", command], {
    cwd: input.cwd,
    env: input.env,
    stdio: "inherit",
  });
  for (const signal of ["SIGTERM", "SIGHUP"])
    process.on(signal, () => child.kill(signal));
  // The terminal sends SIGINT to both processes. The parent must keep the
  // proxies alive while Pi handles cancellation and returns to its prompt.
  process.on("SIGINT", () => {});
  process.exitCode = await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) =>
      resolve(code ?? (signal === "SIGINT" ? 130 : 1)),
    );
  });
} catch (error) {
  process.stderr.write(`alamode: sandbox failed: ${error.message}\n`);
  process.exitCode = 1;
} finally {
  await SandboxManager.reset();
}
