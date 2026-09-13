---
name: agent-trash-guard
description: Move files to recoverable trash instead of deleting them, list what an agent trashed, and restore it with the agent-trash CLI. Trigger when a shell command was blocked with "trash-guard: blocked a permanent delete", when the user asks to delete or clean up files during an agent session, or when the user wants to see or undo something an agent removed. The guard covers common shell delete commands only; it is not universal deletion protection.
---

agent-trash-guard (https://github.com/hermes-labs-ai/agent-trash-guard) has two
parts:

- **Automatic guard.** A pre-tool hook blocks shell commands that permanently
  delete files and tells the agent to use `agent-trash put` instead. It runs
  only where a host adapter is installed and enabled: the Claude Code plugin,
  the Codex plugin after its hook is trusted with `/hooks`, or the Gemini CLI
  extension. This skill alone (for example from `npx skills add`) installs no
  hook.
- **`agent-trash` CLI.** A deterministic, stdlib-only Python tool that moves
  paths into a trash directory and moves them back. It makes no network calls.

## Pick the runner

Use the first of these that works and keep using it:

1. `agent-trash` on `PATH` (the Claude Code plugin adds it while enabled).
2. The exact quoted path printed in the guard's block message, for example
   `"/path/to/plugin/bin/agent-trash"`.
3. `python3 <plugin-or-extension-root>/bin/agent-trash`.

If none exists, tell the user the CLI is not installed. Do not fall back to
`rm`, `mv` into a hand-made folder, or any other improvised delete.

## Delete recoverably

```bash
agent-trash put '<path>' ['<path>' ...]
```

Quote every path. `put` refuses missing, duplicate, or nested (ancestor and
descendant) paths and then moves nothing. On success it prints
`trashed N item(s) -> <id>`, the original absolute paths, and
`restore with: agent-trash restore <id>`. Report the id to the user.

## List

```bash
agent-trash list
```

Prints one line per entry, `<id>  (N item(s), <trashed_at>)`, followed by the
original absolute paths, or `trash is empty (<dir>)`. Ids sort oldest first.

## Restore

```bash
agent-trash restore '<id>'
```

Moves every item in the entry back to its original path, recreating parent
directories. It exits 0 only when every item was restored.

- Exit 1 with `no such entry` means the id is wrong: run `list` and ask.
- Exit 1 with `destination exists, skipping (use --force)` means a newer file
  occupies the path. Show the user the conflict. Pass `--force` only with their
  agreement; the displaced file is kept inside the entry as
  `<name>.displaced`, so it stays recoverable.
- An entry is removed after a complete restore that leaves nothing behind.

## Boundaries

- `agent-trash empty --older-than <days> --yes` is the only permanent delete.
  Run it only when the user explicitly asks to purge trash.
- `TRASH_GUARD_ALLOW=1` bypasses the guard. Use it only after the user
  explicitly approves a specific permanent delete; never add it to get past a
  block on your own.
- The hook inspects shell tool calls (`Bash`, `run_shell_command`) for `rm`,
  `unlink`, `shred`, and `rmdir` in command position, `find -delete`,
  `find -exec rm`, and `git clean -f`. It does not see deletes made through
  file-editing tools, scripts, interpreter one-liners, `bash -c` strings,
  overwrites, truncation, or `git rm`. It is a pattern match that fails open
  on unreadable events, not universal deletion protection.
- Trash lives on the same machine in `$AGENT_TRASH_DIR` (legacy
  `$CLAUDE_TRASH_DIR`, default `~/.claude-trash`). It is not a backup.
