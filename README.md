# agent-trash-guard

A safety net for coding-agent sessions: permanent deletes get blocked, and
files get moved to a recoverable trash directory instead.

Agents are good at cleaning up. Sometimes they clean up the wrong thing, and
`rm` has no undo. This project provides native pre-tool adapters for Claude
Code, Codex, and Gemini CLI, backed by one detector and the `agent-trash` CLI.
Every guarded "delete" becomes a move you can inspect and reverse.

The GitHub repository retains its historical `claude-trash-guard` name for
now. `claude-trash` remains as a compatibility command, while new integrations
and documentation use the platform-neutral `agent-trash-guard` name.

No dependencies beyond Python 3 (stdlib only) and bash.

## Claude Code

Clone the repository, run its isolated checks, then load the repository root as
a local plugin while evaluating it:

```bash
git clone https://github.com/hermes-labs-ai/claude-trash-guard.git
cd claude-trash-guard
./tests/run.sh
claude --plugin-dir "$PWD"
```

The plugin manifest lives at `.claude-plugin/plugin.json`; Claude discovers the
`PreToolUse` hook through `hooks/hooks.json`. The hook invokes only bundled,
plugin-relative files and does not edit `~/.claude/settings.json` or create a
global symlink. When it blocks a delete, its guidance points to the bundled
`bin/claude-trash` command.

`--plugin-dir` is the local evaluation path. The repository also carries a
validated marketplace manifest. Once the marketplace is public and indexed,
installation is one Claude command:

```bash
claude plugin install claude-trash-guard@hermes-labs
```

Until then, do not treat that command as a live public route; use the local
evaluation path above.

## Codex CLI and app

Codex 0.145 or newer can load this repository as a native plugin. Add the local
marketplace, install the neutral plugin entry, then review and trust its hook
with `/hooks`:

```bash
codex plugin marketplace add "$PWD"
codex plugin add agent-trash-guard@hermes-labs
```

The Codex adapter uses `PreToolUse` for `Bash`, the same JSON event consumed by
the shared detector. Codex requires an explicit trust review for non-managed
plugin hooks and skips the hook until that review is complete.

## Gemini CLI

Gemini CLI uses `BeforeTool` and names its shell tool `run_shell_command`. The
bundled installer registers that native mapping without changing Claude or
Codex configuration:

```bash
./integrations/gemini/install.sh
```

Restart Gemini CLI afterwards. Uninstall only that adapter with
`./integrations/gemini/uninstall.sh`.

## Manual Claude installation fallback

```bash
git clone https://github.com/hermes-labs-ai/claude-trash-guard.git
cd claude-trash-guard
./tests/run.sh
./install.sh
```

`install.sh` symlinks `claude-trash` into `~/.local/bin` and registers the hook
in `~/.claude/settings.json` (a timestamped backup is written first, and the
edit is idempotent). Restart any running Claude Code session afterwards.

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
The hook fails open when an event cannot be parsed.

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
```

Covers the hook's block/allow matrix and the full put/list/restore/empty
lifecycle, in an isolated temp directory.

## License

MIT — see [LICENSE](LICENSE).
