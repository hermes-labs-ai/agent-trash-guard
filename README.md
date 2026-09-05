# claude-trash-guard

A safety net for Claude Code sessions: permanent deletes get blocked, and files
get moved to a recoverable trash directory instead.

Agents are good at cleaning up. Sometimes they clean up the wrong thing, and
`rm` has no undo. This project adds a [PreToolUse hook](https://docs.anthropic.com/en/docs/claude-code/hooks)
that intercepts delete commands before they run, plus a small `claude-trash`
CLI the agent (or you) can use instead. Every "delete" becomes a move you can
inspect and reverse.

No dependencies beyond Python 3 (stdlib only) and bash.

## Quick start: native Claude Code plugin

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

## Manual installation fallback

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

When Claude Code is about to run a Bash command that permanently deletes
files, the hook stops it and tells the agent to use `claude-trash put` instead:

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
claude-trash put build/ old-notes.md    # move into ~/.claude-trash, keep originals' paths
claude-trash list                       # show entries with their original locations
claude-trash restore 20260712-153000-4242          # put everything back
claude-trash restore 20260712-153000-4242 --force  # ...even over newer files
claude-trash empty --older-than 7 --yes # the only permanent delete, and it asks twice
```

Each `put` creates one timestamped entry containing the moved files and a
`manifest.json` recording their original absolute paths. `restore` refuses to
overwrite existing files unless you pass `--force` (the displaced file is kept
in the trash entry, so even `--force` loses nothing).

Set `CLAUDE_TRASH_DIR` to relocate the trash (default: `~/.claude-trash`).

## Escape hatch

For a genuine permanent delete that you have explicitly approved, prefix the
command with `TRASH_GUARD_ALLOW=1`:

```bash
TRASH_GUARD_ALLOW=1 rm -rf node_modules
```

The override is deliberately visible in the command itself, so it shows up in
session logs and permission prompts rather than hiding in configuration.

## How it works

`hooks/trash_guard.py` reads the PreToolUse event JSON from stdin. If the tool
is Bash and the command matches a delete pattern, it exits with code 2, which
blocks the call and feeds the guidance on stderr back to the agent. Anything
else exits 0 and runs untouched. The hook fails open: if the event can't be
parsed, it stays out of the way rather than breaking your session.

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
