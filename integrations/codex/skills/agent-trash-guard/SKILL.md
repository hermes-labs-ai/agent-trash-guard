---
name: agent-trash-guard
description: Move files to recoverable trash instead of deleting them, list what an agent trashed, and restore it with the agent-trash CLI. Trigger when trash-guard blocked a permanent delete in a shell command, when the user asks to delete or clean up files during an agent session, or when the user wants to see or undo something an agent removed. The guard covers common shell delete commands only; it is not universal deletion protection.
---

agent-trash-guard (https://github.com/hermes-labs-ai/agent-trash-guard) has two
parts:

- **Automatic guard.** A pre-tool adapter blocks shell commands that permanently
  delete files and tells the agent to use `agent-trash put` instead. It runs
  only where a host adapter is installed and enabled: the Claude Code plugin,
  the Codex plugin after its hook is trusted with `/hooks`, or the native
  Cursor, Gemini CLI, OpenClaw, or Pi integration. This skill alone (for
  example from `npx skills add`) installs no guard.
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
  agreement. `--force` moves the newer file to
  `$AGENT_TRASH_DIR/<id>/<name>.displaced` (or `.displaced.1`, ...). That file
  is not in the manifest: `list` does not show it, `restore` cannot bring it
  back, and `empty` deletes it with the entry. Tell the user its path; it can
  only be recovered by moving it out by hand.
- An entry is removed after a complete restore that leaves nothing behind. An
  entry that still holds a `.displaced` file stays, and restoring it again
  exits 1 with `missing from trash` for the items already restored.

## Reclaim space

```bash
agent-trash gc --roots '<dir>[,<dir>...]' --budget 5G --older-than 14
```

Reports what accumulated storage could be reclaimed and, for everything it
refuses, why. It is a dry run unless `--collect` is passed. Decisions follow one
ordered ladder, first match wins: 1 protected denylist, 2 git state unknown,
3 reachable, 4 newer than the age floor, 5 over budget (collect oldest first),
6 keep. Rule 5 is the only rule that collects, so without `--budget` nothing is
collected at all.

A git checkout is collectable only when its tree is clean, its stash list is
empty, it has no unpushed commits, and `git ls-remote` confirms every local head
on a real remote. If any git call fails the verdict is UNKNOWN and the path is
kept — never report an UNKNOWN as clean. `~/.claude`, `~/ai-infra`,
`~/github-projects`, and anything naming or holding `profiles.db` or
`corpus.db` can never be collected.

Run `gc` in report mode and show the user the receipt. Pass `--collect` only
when they explicitly approve that specific reclaim. Use `--json` when you need
to reason about the result rather than display it.

## Boundaries

- `agent-trash empty --older-than <days> --yes` and `agent-trash gc --collect`
  are the only permanent deletes. Run either only when the user explicitly asks.
- `TRASH_GUARD_ALLOW=1` bypasses the guard. Use it only after the user
  explicitly approves a specific permanent delete; never add it to get past a
  block on your own.
- The hook inspects shell tool calls (`Bash`, `run_shell_command`) for `rm`,
  `unlink`, `shred`, and `rmdir` in command position, `find -delete`,
  `find -exec rm`, and `git clean -f`. It does not see deletes made through
  file-editing tools, scripts, interpreter one-liners, `bash -c` strings,
  overwrites, truncation, or `git rm`. It is a pattern match, not universal
  deletion protection. The Pi adapter blocks when it cannot inspect a shell
  command; failure behavior in other hosts varies.
- Trash lives on the same machine in `$AGENT_TRASH_DIR` (legacy
  `$CLAUDE_TRASH_DIR`, default `~/.claude-trash`). It is not a backup.
