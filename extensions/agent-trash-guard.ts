/** Native Pi pre-tool guard using the repository's canonical detector. */
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const root = fileURLToPath(new URL("../", import.meta.url));
const hook = fileURLToPath(new URL("../hooks/trash_guard.py", import.meta.url));

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;
    const command = event.input.command;
    if (typeof command !== "string") {
      return { block: true, reason: "Trash Guard could not inspect the shell command." };
    }

    const result = spawnSync("python3", [hook], {
      input: JSON.stringify({ tool_name: "Bash", tool_input: { command } }),
      encoding: "utf8",
      timeout: 3000,
      maxBuffer: 128 * 1024,
      env: { ...process.env, AGENT_TRASH_GUARD_ROOT: root },
    });
    if (result.status === 0 && !result.error) return;
    if (result.status === 2) {
      return { block: true, reason: result.stderr.trim() || "Trash Guard blocked a permanent delete." };
    }
    return { block: true, reason: "Trash Guard could not inspect the shell command." };
  });
}
