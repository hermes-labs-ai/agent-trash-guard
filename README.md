# agent-trash-guard

A safety net for coding-agent sessions: permanent deletes get blocked, and
files get moved to a recoverable trash directory instead.

Agents are good at cleaning up. Sometimes they clean up the wrong thing, and
`rm` has no undo. This project provides native pre-tool adapters for Claude
Code, Codex, and Gemini CLI, backed by one detector and the `agent-trash` CLI.
Every guarded "delete" becomes a move you can inspect and reverse.

The project was originally published as `claude-trash-guard`. GitHub redirects
that historical repository URL, and `claude-trash` remains as a compatibility
command. New integrations and documentation use the platform-neutral
`agent-trash-guard` name.

No dependencies beyond Python 3 (stdlib only) and bash.

## Claude Code

Clone the repository, run its isolated checks, then load the Claude adapter
directory while evaluating it:

```bash
git clone https://github.com/hermes-labs-ai/agent-trash-guard.git
cd agent-trash-guard
./tests/run.sh
claude --plugin-dir "$PWD/integrations/claude"
```

The Claude package lives at `integrations/claude/`. Its `PreToolUse` hook and
runtime are self-contained because marketplace installs execute from a private
plugin cache. Do not load the repository root with `--plugin-dir`: the root is
the Gemini extension and has Gemini's `BeforeTool` hook schema.

`--plugin-dir` is the local evaluation path. The repository also carries a
validated marketplace manifest. Once the marketplace is public, install it
with:

```bash
claude plugin marketplace add hermes-labs-ai/agent-trash-guard
claude plugin install claude-trash-guard@hermes-labs
```

Until then, do not treat that command as a live public route; use the local
evaluation path above. `claude-trash-guard` remains the Claude plugin ID for
existing users; `agent-trash` is the neutral bundled command.

## Codex CLI and app

Codex 0.145 or newer can load the self-contained Codex adapter from this
repository's marketplace. Add the local marketplace, install the neutral plugin
entry, then review and trust its hook with `/hooks`:

```bash
codex plugin marketplace add "$PWD"
codex plugin add agent-trash-guard@hermes-labs
```

The Codex package is `integrations/codex/` and uses `PreToolUse` for `Bash`.
Codex requires an explicit trust review for non-managed plugin hooks and skips
the hook until that review is complete.

## Gemini CLI

Gemini CLI is the repository-root extension. It uses `BeforeTool` and names
its shell tool `run_shell_command`:

```bash
gemini extensions install https://github.com/hermes-labs-ai/agent-trash-guard
```

Restart Gemini CLI afterwards. Update or uninstall it with:

```bash
gemini extensions update agent-trash-guard
gemini extensions uninstall agent-trash-guard
```

The root `gemini-extension.json` makes this repository eligible for Gemini's
Gallery crawler when the public repository has the `gemini-cli-extension` topic
and a tagged release. The nested Claude and Codex package roots intentionally
do not qualify as Gemini extensions.

For local development use `gemini extensions link "$PWD"`. The old
`integrations/gemini/install.sh` and `uninstall.sh` remain only to remove or
maintain a pre-extension settings-based installation; they are not the primary
installation route.

## Manual Claude installation fallback

```bash
git clone https://github.com/hermes-labs-ai/agent-trash-guard.git
cd agent-trash-guard
./tests/run.sh
./install.sh
```

`install.sh` symlinks `claude-trash` into `~/.local/bin` and registers the
Claude adapter in `~/.claude/settings.json` (a timestamped backup is written
first, and the edit is idempotent). Restart any running Claude Code session
afterwards. `uninstall.sh` removes only that exact legacy hook command, leaving
other `trash_guard.py` hooks alone.

## What gets blocked

When a supported agent is about to run a shell command that permanently
deletes files, the hook stops it and tells the agent to use `agent-trash put`
instead:

- `rm`, `unlink`, `shred`, `rmdir` — in command position, including behind
  `sudo`, `env`, `nohup`, `time`, `xargs`, pipes, `&&`/`;` chains, subshells,
  and absolute paths like `/bin/rm`
- `find ... -delete` and `find ... -exec rm ...`
- `git clean -f` (and `-fd`, `-fdx`, ...)

Not blocked, by design:

- `git rm` — the file is still recoverable from git history
- `rm` appearing as a plain word (`echo rm is just a word`)
- overwrites and truncations — out of scope for v0.1

## Using the trash

```bash
agent-trash put build/ old-notes.md    # move into ~/.claude-trash, keep originals' paths
agent-trash list                       # show entries with their original locations
agent-trash restore 20260712-153000-4242          # put everything back
agent-trash restore 20260712-153000-4242 --force  # ...even over newer files
agent-trash empty --older-than 7 --yes # the only permanent delete, and it asks twice
```

Each `put` creates one timestamped entry containing the moved files and a
`manifest.json` recording their original absolute paths. `restore` refuses to
overwrite existing files unless you pass `--force` (the displaced file is kept
in the trash entry, so even `--force` loses nothing).

Set `AGENT_TRASH_DIR` to relocate the trash (default: `~/.claude-trash`). The
legacy `CLAUDE_TRASH_DIR` variable remains supported.

## Escape hatch

For a genuine permanent delete that you have explicitly approved, prefix the
command with `TRASH_GUARD_ALLOW=1`:

```bash
TRASH_GUARD_ALLOW=1 rm -rf node_modules
```

The override is deliberately visible in the command itself, so it shows up in
session logs and permission prompts rather than hiding in configuration.

## How it works

`hooks/trash_guard.py` reads a pre-tool event as JSON on stdin. It accepts the
Claude/Codex `Bash` and Gemini `run_shell_command` names. If the command matches
a delete pattern, it exits with code 2, which all three runtimes define as a
blocking decision whose stderr becomes agent guidance. Anything else exits 0.
The hook fails open when an event cannot be parsed. The runtime files inside
`integrations/claude` and `integrations/codex` are generated copies required by
plugin-cache isolation; do not edit them. Regenerate with
`python3 tools/build_platform_bundles.py` and verify with `--check`.

## Other agents

OpenClaw has a native `before_tool_call` plugin hook capable of blocking an
`exec` call. It requires a TypeScript provider plugin rather than this
JSON-over-stdin adapter, so it is not claimed as supported here yet. No local
Hermes Agent/client installation exposed a verified pre-tool interception API;
the `hermes` command on this machine is the Hermes Labs command center, not an
agent runtime. Both are adapter candidates, not live integrations.

## Uninstall

For the native plugin path, end the `claude --plugin-dir` session or remove the
plugin through Claude Code's plugin manager. Trash contents remain untouched.

For the manual fallback:

```bash
./uninstall.sh
```

Removes the hook entry and the symlink. Your trash directory is left intact.

## Tests

```bash
./tests/run.sh
python3 tools/build_platform_bundles.py --check
```

Covers the hook's block/allow matrix, the full put/list/restore/empty
lifecycle, and the quality rail's review range, in an isolated temp directory.

The Hermes Gate rail in `.hermes/` keeps its local scope — worktree, index and
untracked bytes — when run with no arguments. A hosted checkout has none of
those, so CI names the range explicitly:

```bash
python3 .hermes/hermes_gate_runner.py full --base "$PULL_REQUEST_BASE_SHA"
python3 .hermes/hermes_gate_runner.py full --all
```

`--base` compares that revision with `HEAD` (`HERMES_GATE_BASE` does the same),
`--all` reviews every committed byte, and a base the checkout does not carry is
an error rather than an empty scan. `full` runs every declared stage and reports
each one; `fast` still stops at the first failure to hold its local budget.

## Recoverability proof

[`tests/recoverability-demo.sh`](tests/recoverability-demo.sh) is a
self-contained, deterministic proof that the guard blocks a destructive command
and that the trash workflow loses nothing. It runs entirely inside a freshly
created temporary directory, validates that path before cleaning up, and never
touches user files or the real trash directory.

```bash
./tests/recoverability-demo.sh
```

Using the released hook event interface and the `agent-trash` CLI, it shows:

1. a representative `rm -rf FILE` event is blocked (hook exit 2) and the file
   stays in place
2. the recommended replacement, `agent-trash put FILE`, passes the hook
3. `agent-trash put` moves the file into a timestamped trash entry
4. `agent-trash list` exposes the entry and the file's original path
5. `agent-trash restore <id>` returns the file to its original path
6. the restored file's SHA-256 equals the original, pinned digest

The script stops at the first failed step with a non-zero exit and prints
`RESULT: PASS (6/6)` when the proof holds.

## License

MIT — see [LICENSE](LICENSE).
