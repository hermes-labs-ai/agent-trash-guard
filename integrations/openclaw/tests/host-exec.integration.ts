/**
 * Optional real-host exercise. Run with OpenClaw's tsx runtime; see ../README.md.
 * This deliberately loads the actual plugin registry and invokes the actual
 * host exec tool through its before_tool_call wrapper. It has no model path.
 */
import assert from "node:assert/strict";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const hostRoot = process.env.OPENCLAW_SOURCE_DIR;
if (!hostRoot) {
  throw new Error("Set OPENCLAW_SOURCE_DIR to the OpenClaw source checkout.");
}
// The real gateway executor probes the login shell to augment PATH. Keep this
// isolated fixture fast without changing user configuration; the inherited PATH
// already contains python3 and the commands used below.
process.env.OPENCLAW_SHELL_ENV_TIMEOUT_MS ??= "1";
const adapterRoot = resolve(import.meta.dirname, "..");
const hostModule = (relative: string) =>
  import(pathToFileURL(join(hostRoot, "src", relative)).href);

const { loadOpenClawPlugins } = await hostModule("plugins/loader.ts");
const { createExecTool } = await hostModule("agents/bash-tools.exec.ts");
const { wrapToolWithBeforeToolCallHook } = await hostModule("agents/pi-tools.before-tool-call.ts");

const registry = loadOpenClawPlugins({
  config: {
    plugins: {
      enabled: true,
      allow: ["agent-trash-guard"],
      load: { paths: [adapterRoot] },
      entries: { "agent-trash-guard": { enabled: true } },
    },
  },
  onlyPluginIds: ["agent-trash-guard"],
  cache: false,
  throwOnLoadError: true,
});
const plugin = registry.plugins.find((candidate: { id: string }) => candidate.id === "agent-trash-guard");
assert.equal(plugin?.status, "loaded");
assert.equal(plugin?.hookCount, 1, "the native registry must contain the adapter hook");

const work = await mkdtemp(join(tmpdir(), "agent-trash-openclaw-host-"));
const trash = join(work, "trash");
const fixture = join(work, "fixture.bin");
const original = Buffer.from([0x00, 0x68, 0x65, 0x72, 0x6d, 0x65, 0x73, 0xff, 0x0a]);
const quote = (value: string) => `'${value.replaceAll("'", "'\\\"'\\\"'")}'`;
const exec = wrapToolWithBeforeToolCallHook(
  createExecTool({ host: "gateway", security: "full", ask: "off", cwd: work, allowBackground: false }),
);
const run = async (command: string) =>
  exec.execute(`host-${Math.random()}`, {
    command,
    workdir: work,
    env: { AGENT_TRASH_DIR: trash },
  });

try {
  const safeResult = await run("printf safe-host-exec");
  assert.match(JSON.stringify(safeResult), /safe-host-exec/);
  await writeFile(fixture, original);
  await assert.rejects(run(`rm -f ${quote(fixture)}`), /Permanent delete blocked/);
  assert.deepEqual(await readFile(fixture), original);
  await assert.rejects(run(`sh -c ${quote(`rm -f ${quote(fixture)}`)}`), /Permanent delete blocked/);
  assert.deepEqual(await readFile(fixture), original);

  const cli = join(adapterRoot, "bin", "agent-trash");
  await run(`python3 ${quote(cli)} put ${quote(fixture)}`);
  const entries = (await readdir(trash)).filter((entry) => !entry.startsWith("."));
  assert.equal(entries.length, 1);
  await assert.rejects(readFile(fixture));
  await run(`python3 ${quote(cli)} list`);
  await run(`python3 ${quote(cli)} restore ${quote(entries[0])}`);
  assert.deepEqual(await readFile(fixture), original);
  process.stderr.write(
    "PASS native OpenClaw exec hook: safe, direct/nested block, bundled put/list/restore bytes identical\\n",
  );
} finally {
  await rm(work, { recursive: true, force: true });
}
