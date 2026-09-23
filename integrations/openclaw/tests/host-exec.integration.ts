/**
 * Optional real-host exercise. Run with OpenClaw's tsx runtime; see ../README.md.
 * This deliberately loads the actual plugin registry and invokes the actual
 * host exec tool through its before_tool_call wrapper. It has no model path.
 */
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const hostRoot = process.env.OPENCLAW_SOURCE_DIR;
if (!hostRoot) {
  throw new Error("Set OPENCLAW_SOURCE_DIR to the OpenClaw source checkout.");
}
const profile = await mkdtemp(join(tmpdir(), "agent-trash-openclaw-profile-"));
const profileHome = join(profile, "home");
const stateDir = join(profile, "state");
const savedEnvironment = Object.fromEntries(
  ["HOME", "OPENCLAW_STATE_DIR", "OPENCLAW_CONFIG_PATH", "TRASH_GUARD_ALLOW"].map((key) => [
    key,
    process.env[key],
  ]),
);
await Promise.all([mkdir(profileHome), mkdir(stateDir)]);
await writeFile(join(stateDir, "openclaw.json"), "{}\n", "utf8");
process.env.HOME = profileHome;
process.env.OPENCLAW_STATE_DIR = stateDir;
process.env.OPENCLAW_CONFIG_PATH = join(stateDir, "openclaw.json");
delete process.env.TRASH_GUARD_ALLOW;
const hostPackage = JSON.parse(await readFile(join(hostRoot, "package.json"), "utf8")) as {
  version?: string;
};
assert.equal(hostPackage.version, "2026.9.5", "this spike is pinned to OpenClaw 2026.9.5");
// The real gateway executor probes the login shell to augment PATH. Keep this
// isolated fixture fast without changing user configuration; the inherited PATH
// already contains python3 and the commands used below.
process.env.OPENCLAW_SHELL_ENV_TIMEOUT_MS ??= "1";
const adapterRoot = resolve(import.meta.dirname, "..");
const hostModule = (relative: string) =>
  import(pathToFileURL(join(hostRoot, "src", relative)).href);

const { loadOpenClawPlugins } = await hostModule("plugins/loader.ts");
const { initializeGlobalHookRunner, getGlobalHookRunner, resetGlobalHookRunner } = await hostModule(
  "plugins/hook-runner-global.ts",
);
const { createHookRunner } = await hostModule("plugins/hooks.ts");
const { createExecTool } = await hostModule("agents/bash-tools.exec-run.ts");
const { wrapToolWithBeforeToolCallHook } = await hostModule(
  "agents/agent-tools.before-tool-call.wrapper.ts",
);

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
initializeGlobalHookRunner(registry);
assert.equal(getGlobalHookRunner()?.hasHooks("before_tool_call"), true);
const directDecision = await getGlobalHookRunner()?.runBeforeToolCall(
  { toolName: "exec", params: { command: "rm -rf blocked-fixture" } },
  { toolName: "exec" },
);
assert.equal(directDecision?.block, true);
assert.equal(
  directDecision?.blockReason,
  "Permanent delete blocked; use recoverable trash instead.",
);
const unrelatedTool = await createHookRunner(registry).runBeforeToolCall(
  { toolName: "read", params: {} },
  { toolName: "read" },
);
assert.equal(unrelatedTool, undefined, "the exec-only matcher must leave unrelated tools alone");

const work = await mkdtemp(join(tmpdir(), "agent-trash-openclaw-host-"));
const trash = join(work, "trash");
const fixture = join(work, "fixture.bin");
const original = Buffer.from([0x00, 0x68, 0x65, 0x72, 0x6d, 0x65, 0x73, 0xff, 0x0a]);
const quote = (value: string) => `'${value.replaceAll("'", "'\\\"'\\\"'")}'`;
const exec = wrapToolWithBeforeToolCallHook(
  createExecTool({
    host: "gateway",
    security: "full",
    ask: "off",
    allowBackground: false,
  }),
);
assert.equal(exec.name, "exec", "the native host tool must match the integration's bounded matcher");
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
  const blockedResult = await run(`rm -f ${quote(fixture)}`).then(
    (result: unknown) => ({ result }),
    (error: unknown) => ({ error: String(error) }),
  );
  assert.match(JSON.stringify(blockedResult), /Permanent delete blocked/);
  assert.deepEqual(await readFile(fixture), original);
  const nestedBlockedResult = await run(`sh -c ${quote(`rm -f ${quote(fixture)}`)}`).then(
    (result: unknown) => ({ result }),
    (error: unknown) => ({ error: String(error) }),
  );
  assert.match(JSON.stringify(nestedBlockedResult), /Permanent delete blocked/);
  assert.deepEqual(await readFile(fixture), original);

  const cli = join(adapterRoot, "bin", "agent-trash");
  await run(`python3 ${quote(cli)} put ${quote(fixture)}`);
  const entries = (await readdir(trash)).filter((entry) => !entry.startsWith("."));
  assert.equal(entries.length, 1);
  await assert.rejects(readFile(fixture));
  await run(`python3 ${quote(cli)} list`);
  await run(`python3 ${quote(cli)} restore ${quote(entries[0])}`);
  assert.deepEqual(await readFile(fixture), original);

  const disabledRegistry = loadOpenClawPlugins({
    config: {
      plugins: {
        enabled: true,
        allow: ["agent-trash-guard"],
        load: { paths: [adapterRoot] },
        entries: { "agent-trash-guard": { enabled: false } },
      },
    },
    onlyPluginIds: ["agent-trash-guard"],
    cache: false,
    throwOnLoadError: true,
  });
  initializeGlobalHookRunner(disabledRegistry);
  assert.equal(
    getGlobalHookRunner()?.hasHooks("before_tool_call"),
    false,
    "disabling the plugin must remove its hook from the runtime registry",
  );
  process.stderr.write(
    "PASS native OpenClaw exec hook: safe, direct/nested block, bundled put/list/restore bytes identical\\n",
  );
} finally {
  resetGlobalHookRunner();
  await rm(work, { recursive: true, force: true });
  await rm(profile, { recursive: true, force: true });
  for (const [key, value] of Object.entries(savedEnvironment)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
}
