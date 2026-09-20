import assert from "node:assert/strict";
import test from "node:test";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { checkCommand, reasons } from "../bridge.js";
import { registerTrashGuard } from "../entry.js";

const execFileAsync = promisify(execFile);

test("bundled detector stays byte-identical to the canonical detector", async () => {
  const bundled = await readFile(new URL("../hooks/trash_guard.py", import.meta.url));
  const canonical = await readFile(new URL("../../../hooks/trash_guard.py", import.meta.url));
  assert.deepEqual(bundled, canonical);
});

test("bundled CLI reports its OpenClaw manifest version", async () => {
  const cli = new URL("../bin/agent-trash", import.meta.url);
  const { stdout } = await execFileAsync("python3", [fileURLToPath(cli), "--version"]);
  assert.equal(stdout.trim(), "agent-trash 0.1.3");
});

test("registers only for exec and fails closed on malformed exec parameters", async () => {
  let registration;
  registerTrashGuard({
    on(...args) {
      registration = args;
    },
  });
  const [hookName, handler, options] = registration;
  assert.equal(hookName, "before_tool_call");
  assert.deepEqual(options, { matcher: ["exec"] });
  assert.deepEqual(await handler({}), {
    block: true,
    blockReason: reasons.UNAVAILABLE_REASON,
  });
  assert.deepEqual(await handler({ params: { command: 42 } }), {
    block: true,
    blockReason: reasons.UNAVAILABLE_REASON,
  });
  assert.equal(await handler({ params: { command: "ls" } }), undefined);
});

test("allows safe commands", async () => {
  assert.deepEqual(await checkCommand("ls -la"), { block: false });
});

test("blocks destructive and nested commands without echoing the command", async () => {
  for (const command of ["rm -rf delete-me", "bash -c 'rm -rf delete-me'"]) {
    const decision = await checkCommand(command);
    assert.deepEqual(decision, { block: true, reason: reasons.BLOCKED_REASON });
    assert.equal(decision.reason.includes("delete-me"), false);
  }
});

test("preserves the canonical one-command override", async () => {
  assert.deepEqual(await checkCommand("TRASH_GUARD_ALLOW=1 rm -rf delete-me"), { block: false });
});

test("blocks when the bridge is missing or times out", async () => {
  const missing = await checkCommand("ls", { bridgePath: "/does/not/exist.py" });
  assert.deepEqual(missing, { block: true, reason: reasons.UNAVAILABLE_REASON });
  const directory = await mkdtemp(join(tmpdir(), "trash-guard-test-"));
  const slowBridge = join(directory, "slow.py");
  await writeFile(slowBridge, "import time\ntime.sleep(5)\n", "utf8");
  const timeout = await checkCommand("ls", { bridgePath: slowBridge, timeoutMs: 20 });
  assert.deepEqual(timeout, { block: true, reason: reasons.UNAVAILABLE_REASON });
});
