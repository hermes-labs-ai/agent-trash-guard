import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const MAX_OUTPUT_BYTES = 4096;
const MAX_COMMAND_BYTES = 131072;
const BRIDGE_TIMEOUT_MS = 1500;
const bridgePath = fileURLToPath(new URL("./hooks/trash_guard.py", import.meta.url));

const BLOCKED_REASON = "Permanent delete blocked; use recoverable trash instead.";
const UNAVAILABLE_REASON = "Trash guard could not verify this command; execution blocked.";

/** Run the canonical detector without forwarding its potentially sensitive stderr. */
export function checkCommand(command, options = {}) {
  if (Buffer.byteLength(command, "utf8") > MAX_COMMAND_BYTES) {
    return Promise.resolve({ block: true, reason: UNAVAILABLE_REASON });
  }
  const python = options.python ?? "python3";
  const detector = options.bridgePath ?? bridgePath;
  const timeoutMs = options.timeoutMs ?? BRIDGE_TIMEOUT_MS;
  // Python also uses exit 2 for a missing script, which is otherwise
  // indistinguishable from the detector's block decision.
  if (!existsSync(detector)) {
    return Promise.resolve({ block: true, reason: UNAVAILABLE_REASON });
  }
  return new Promise((resolve) => {
    let done = false;
    let outputBytes = 0;
    let timer;
    const finish = (result) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve(result);
    };
    let child;
    try {
      child = spawn(python, [detector], { stdio: ["pipe", "pipe", "pipe"] });
    } catch {
      finish({ block: true, reason: UNAVAILABLE_REASON });
      return;
    }
    const failClosed = () => {
      child.kill();
      finish({ block: true, reason: UNAVAILABLE_REASON });
    };
    const countOutput = (chunk) => {
      outputBytes += chunk.length;
      if (outputBytes > MAX_OUTPUT_BYTES) failClosed();
    };
    child.stdout.on("data", countOutput);
    child.stderr.on("data", countOutput);
    child.on("error", () => finish({ block: true, reason: UNAVAILABLE_REASON }));
    child.on("close", (code) => {
      if (code === 0) finish({ block: false });
      else if (code === 2) finish({ block: true, reason: BLOCKED_REASON });
      else finish({ block: true, reason: UNAVAILABLE_REASON });
    });
    child.stdin.on("error", failClosed);
    timer = setTimeout(failClosed, timeoutMs);
    child.stdin.end(JSON.stringify({ tool_name: "Bash", tool_input: { command } }));
  });
}

export const reasons = { BLOCKED_REASON, UNAVAILABLE_REASON };
