# OpenClaw adapter

Install, plugin inspection, and the native `exec`-tool flow were tested with
OpenClaw 2026.9.5 (source tag `v2026.9.5`).

This native plugin registers a `before_tool_call` hook for `exec`. It bridges
`event.params.command` to the bundled canonical detector and returns OpenClaw's
terminal `{ block: true }` decision for permanent deletes or detector failures.
Detector output is never included in the tool error because it can contain the
command text.

For a local installation:

```bash
git clone https://github.com/hermes-labs-ai/agent-trash-guard.git
cd agent-trash-guard
openclaw plugins install -l ./integrations/openclaw
openclaw plugins inspect agent-trash-guard --json
```

The package is hook-only and needs no account configuration or credentials.
It was loaded in an isolated OpenClaw profile during validation.

Restart your OpenClaw gateway after installation to load the hook for subsequent tool calls.

## What a user sees

The hook applies only to OpenClaw's native `exec` tool. It checks the complete
command before the host executor starts it. A normal command runs; a recognized
permanent delete is rejected with `Permanent delete blocked; use recoverable
trash instead.` The hook blocks the command; it does not automatically move
anything to trash.

Use the bundled recovery CLI after a block:

```bash
# Run from the plugin root if your host has not exposed plugin bin/ on PATH.
./bin/agent-trash put ./notes.txt
./bin/agent-trash list
./bin/agent-trash restore ENTRY_ID
```

`put` prints `ENTRY_ID`. `list` lets you choose that ID later and shows the
original path. `restore ENTRY_ID` returns the saved bytes to that path and
refuses to overwrite a newer file unless `--force` is supplied.

The detector intentionally covers selected shell command patterns (including
`rm`, nested shell `-c`, `find -delete`, and `git clean -f`). It does not
provide automatic trashing, a general filesystem monitor, or protection for
every deletion mechanism, overwrite, or truncation.

## Reproduce the native tool-path check

With an OpenClaw `v2026.9.5` source checkout, this test loads the adapter through
OpenClaw's real plugin registry, initializes its global hook runner, wraps the
real `createExecTool`, and executes fixture commands. It makes no model call.
The adapter package declares OpenClaw as an optional peer so the host can link
its SDK into the isolated plugin runtime; `openclaw.compat.pluginApi` pins the
tested compatibility floor.

```bash
git clone --depth 1 --branch v2026.9.5 https://github.com/openclaw/openclaw.git /tmp/openclaw-v2026.9.5
cd /tmp/openclaw-v2026.9.5
pnpm install --frozen-lockfile
pnpm build
OPENCLAW_SOURCE_DIR="$PWD" \
  node_modules/.bin/tsx \
  /path/to/agent-trash-guard/integrations/openclaw/tests/host-exec.integration.ts
```

It proves a safe host `exec` runs, direct and nested deletes are blocked while
fixture bytes remain intact, and `put` → `list` → `restore` through the bundled
CLI returns the exact original bytes. It uses only a temporary fixture and
does not start or restart a gateway. The test uses a temporary OpenClaw home
and state directory, leaving the operator's configuration untouched. It also verifies that a `read` tool call
is outside the `exec` matcher and that disabling this plugin removes its hook
from the host registry. The test fails unless the checkout is exactly version
2026.9.5. Run it from the OpenClaw source root so its loader can resolve the
native plugin SDK.
