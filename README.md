<div align="center">

<h1>Agent Trash Guard</h1>

<p>
  <img src="assets/agent-trash-guard-artwork.jpg" width="900" alt="Agent Trash Guard artwork: an armored guardian protecting systems from unsafe deletion" />
</p>

<p><strong>A safety net for coding-agent sessions: block permanent deletes and keep recovery within reach.</strong></p>

<p>Agent Trash Guard is developed by <a href="https://hermes-labs.ai">Hermes Labs</a>.</p>

<p>Hermes Labs is an agentic infrastructure company building the reliability layer for autonomous systems.</p>

<a href="https://github.com/hermes-labs-ai/agent-trash-guard/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/hermes-labs-ai/agent-trash-guard?display_name=tag&amp;sort=semver"></a>
<a href="https://github.com/hermes-labs-ai/agent-trash-guard/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/hermes-labs-ai/agent-trash-guard/actions/workflows/ci.yml/badge.svg"></a>
<a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/License-Apache--2.0-blue.svg"></a>

<p>
<a href="#install">Install</a> ·
<a href="#what-gets-blocked">What gets blocked</a> ·
<a href="#using-the-trash">Recovery workflow</a> ·
<a href="#how-it-works">How it works</a> ·
<a href="#tests">Tests</a>
</p>

</div>

<p>Native guards for Claude Code, Codex, Cursor, Gemini CLI, OpenClaw, and Pi, backed by one detector and an inspectable <code>agent-trash</code> workflow.</p>

Agents are good at cleaning up. Sometimes they clean up the wrong thing, and
`rm` has no undo. This project provides native pre-tool adapters for Claude
Code, Codex, Cursor, Gemini CLI, OpenClaw, and Pi, backed by one detector and the `agent-trash` CLI.
Recognized guarded delete commands are blocked before execution; use
`agent-trash put` to make the recoverable move you can inspect and reverse.
`agent-trash gc` reclaims the space those moves accumulate without ever
reclaiming work that git cannot prove is safe to lose.

The project was originally published as `claude-trash-guard`. GitHub redirects
that historical repository URL, and `claude-trash` remains as a compatibility
command. New integrations and documentation use the platform-neutral
`agent-trash-guard` name.

No dependencies beyond Python 3 (stdlib only) and bash.

## Install

The repository root is one portable Agent Plugin (`plugin.json`, Agent Plugins
1.0.0) with one canonical skill, `skills/agent-trash-guard/SKILL.md`. Choose a
host route that loads the executable guard. A skill-only install teaches the
workflow but cannot intercept shell commands.

| Host | Install | Read back |
| --- | --- | --- |
| Claude Code | `claude plugin marketplace add hermes-labs-ai/agent-trash-guard && claude plugin install agent-trash-guard@hermes-labs` | `claude plugin list` |
| Codex CLI | `codex plugin marketplace add hermes-labs-ai/agent-trash-guard && codex plugin add agent-trash-guard@hermes-labs` | `codex plugin list`, then trust the hook with `/hooks` |
| Cursor | Clone the repository, then copy `integrations/cursor/` to `~/.cursor/plugins/local/agent-trash-guard/` | Restart Cursor; inspect Customize → Plugins and test a disposable delete |
| Gemini CLI | `gemini extensions install https://github.com/hermes-labs-ai/agent-trash-guard --ref main` | `gemini skills list` |
| OpenClaw | `openclaw plugins install ./integrations/openclaw` | `openclaw plugins inspect agent-trash-guard --json` |
| Pi | `pi install git:github.com/hermes-labs-ai/agent-trash-guard@main` | `pi list`, then test a disposable delete in Pi's Bash tool |
| skills.sh (skill only) | `npx skills add https://github.com/hermes-labs-ai/agent-trash-guard --skill agent-trash-guard` | `npx skills list` |

The skill teaches an agent to use `agent-trash put`, `list`, and `restore`
and states the guard's limits. A skills.sh install copies only the skill; it
installs no hook and no CLI.

### First safe check

The host readback above confirms that the plugin, extension, or skill was
registered; it does not by itself prove that a delete hook is active. After a
native plugin or extension install (not a skills.sh-only install), run:

```bash
agent-trash --version
agent-trash list
```

Both are read-only: `--version` prints the installed CLI's bundled version
(read from that host's own `plugin.json`/manifest, so it always matches what
was actually installed), and `list` shows the configured trash. Neither moves
or deletes anything. In Codex, also complete the explicit `/hooks` trust
review before treating delete interception as active. Until then, Codex loads
the skill but skips its non-managed hook.

The guard is a convenience layer, not universal deletion protection: it fails
open when it cannot parse a Claude/Codex/Gemini hook event. The Cursor, OpenClaw,
and Pi adapters fail closed when they cannot inspect a shell command. All hosts
have documented command-pattern limits, and the local trash is not a backup.
Keep normal backups and inspect the
supported-command boundaries below before relying on it for an important path.

### OpenClaw: recover one file end to end

The OpenClaw adapter intercepts the native `exec` tool. It blocks a recognized
permanent-delete command; it does **not** rewrite that command into a trash
operation. After the block, run the recoverable CLI yourself (or instruct the
agent to run it):

```bash
# From this repository checkout, install the adapter and restart the gateway.
openclaw plugins install -l ./integrations/openclaw
openclaw plugins inspect agent-trash-guard --json

# In an OpenClaw exec session, this is rejected before rm receives the file.
rm -f notes.txt

# Use the bundled recoverable CLI instead. (Use `agent-trash` if your host
# exposes plugin bin directories on PATH.)
./integrations/openclaw/bin/agent-trash put notes.txt
./integrations/openclaw/bin/agent-trash list
# Copy the entry ID printed by `put` (for example, 20260919-153000-4242).
./integrations/openclaw/bin/agent-trash restore 20260919-153000-4242
```

Before `put`, `notes.txt` is at its original path. After `put`, it is absent
there and `list` shows the entry ID and original path. After `restore ID`, the
same bytes are back at the original path. `restore` refuses to replace a newer
file unless `--force` is explicit. The adapter packages that CLI at
`integrations/openclaw/bin/agent-trash`.

This is an `exec`-tool guard, not an LLM conversation test or a general file
system monitor. It recognizes the documented shell delete patterns and leaves
other deletion mechanisms, overwrites, and truncation outside its scope.

## Claude Code

`agent-trash-guard@hermes-labs` is the repository root. Its manifest reuses the
`PreToolUse` hook in `integrations/claude/hooks/hooks.json`, which runs the
root `hooks/trash_guard.py`, and its `bin/` puts `agent-trash` on the Bash
tool's `PATH` while the plugin is enabled.

`claude-trash-guard@hermes-labs` remains the guard-only plugin ID for existing
users (`integrations/claude/`). Install one of the two, not both, or every
blocked command is reported twice. `claude plugin validate --strict` on the
root manifest reports the Gemini `BeforeTool` entry in the root
`hooks/hooks.json` as ignored at runtime; that warning is expected.

To evaluate a local checkout:

```bash
git clone https://github.com/hermes-labs-ai/agent-trash-guard.git
cd agent-trash-guard
./tests/run.sh
claude --plugin-dir "$PWD"
```

## Codex CLI and app

Codex 0.145 or newer installs `agent-trash-guard@hermes-labs` from the
self-contained `integrations/codex/` adapter, which uses `PreToolUse` for
`Bash`. Codex requires an explicit trust review for non-managed plugin hooks
and skips the hook until you trust it with `/hooks`; the skill works either
way.

Codex ignores a `.codex-plugin` manifest, and with it these hooks, when a
portable root `plugin.json` exists, so its marketplace entry points at the
adapter. The adapter's `skills/agent-trash-guard/SKILL.md` is a generated byte
copy of the canonical skill, checked like the runtime copies below. For a
local checkout use `codex plugin marketplace add "$PWD"`.

## Gemini CLI

Gemini CLI is the repository-root extension. It uses `BeforeTool`, names its
shell tool `run_shell_command`, and discovers the skill under `skills/`:

```bash
gemini extensions install https://github.com/hermes-labs-ai/agent-trash-guard --ref main
```

Keep `--ref main`: without a ref, Gemini CLI installs the latest release
archive, and releases up to v0.1.2 predate the skill.

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

## Cursor

Cursor loads the self-contained bundle at `integrations/cursor/`. Until a
marketplace listing is available, use Cursor's documented local-plugin path:

```bash
git clone https://github.com/hermes-labs-ai/agent-trash-guard.git
mkdir -p ~/.cursor/plugins/local
cp -R agent-trash-guard/integrations/cursor ~/.cursor/plugins/local/agent-trash-guard
```

Restart Cursor and inspect Customize → Plugins. In an IDE agent session, create
a disposable file and ask Cursor to run `rm FILE_PATH` as a shell command. The
`beforeShellExecution` hook denies it and gives the bundled `agent-trash` path.
Run that path with `put FILE_PATH`, `list`, then `restore ENTRY_ID`; the same
file should return. Copying the bundle does not add a global `agent-trash`
command. Remove `~/.cursor/plugins/local/agent-trash-guard` to uninstall this
local plugin. Cursor's Tab edits and non-shell tools are outside this hook.
When updating this local copy, remove only
`~/.cursor/plugins/local/agent-trash-guard` before repeating the copy command;
otherwise `cp -R` can nest a second `cursor/` directory under the old bundle.

## Pi

Pi loads the root `skills/` and `extensions/` directories from a Git package:

```bash
pi install git:github.com/hermes-labs-ai/agent-trash-guard@main
pi list
```

Start a new Pi session (or `/reload` an existing one). The TypeScript extension
intercepts Pi's `bash` tool at `tool_call` and asks the canonical Python detector
to decide before the shell runs. It needs Python 3 on `PATH`. In Pi, create a
disposable file, then ask for `rm FILE_PATH`: the tool should be blocked and the
file should remain. Use the exact bundled `bin/agent-trash` path in the block
message with `put FILE_PATH`, `list`, and `restore ENTRY_ID` to verify recovery.
`pi list` proves package registration, not that the guard blocked a command.
Remove it with `pi remove git:github.com/hermes-labs-ai/agent-trash-guard@main`.

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

## Retention: `agent-trash gc`

A recoverable delete only moves the problem: guarded deletes, dated task
worktrees, and approved-for-deletion dumps pile up until the disk is full of
quarantined garbage. `agent-trash gc` reaps that accumulation, and it is built
so that it can only ever reap work that nothing still points at.

**Budget decides *when* to collect. Reachability decides *what* may be
collected.** The size budget is the trigger, the way BuildKit's `keepStorage`
or ccache's `max_size` are; reachability is the Nix GC-root model, so anything
still reachable from something that matters is never a candidate.

```bash
# report only (the default): what would gc reclaim, and why did it refuse the rest
agent-trash gc --roots ~/.claude-trash,~/worktrees --budget 5G --older-than 14

# the full machine-readable receipt, one JSON object with an entry per decision
agent-trash gc --roots ~/.claude-trash --budget 5G --json

# actually reclaim; deleting always needs this explicit flag
agent-trash gc --roots ~/.claude-trash --budget 5G --older-than 14 --collect
```

### The decision ladder

Every candidate runs the same ordered ladder, first match wins, and every
receipt names the rule number that decided it:

| # | Rule | Outcome |
|---|------|---------|
| 1 | **Protected** — the denylist | never collect, overrides everything below |
| 2 | **Unknown** — git could not answer | never collect; unknown is treated as reachable |
| 3 | **Reachable** — something still points at it | never collect |
| 4 | **Too young** — newer than `--older-than` | never collect; budget pressure does not lower the floor |
| 5 | **Budget** — footprint exceeds `--budget` | collect, oldest first, until the footprint fits |
| 6 | **Default** | keep |

Rule 5 is the only rule that ever collects anything. Without `--budget`,
nothing triggers collection at all; `--budget 0` means "collect everything the
first four rules allow".

### What "unreachable" means

A directory holding git checkouts is unreachable only when *every* checkout
inside it passes *all* of these:

- `git status --porcelain --untracked-files=all` is empty
- `git stash list` is empty
- `git log --branches --not --remotes --oneline` is empty
- every local branch head, and `HEAD`, is confirmed present on a real remote by
  `git ls-remote` — not by `git branch -r`, which reads a stale local cache and
  will happily claim a branch is on a remote that never received it

The last check is a `git rev-list --count` of the head against everything the
remote just advertised, not a string comparison of SHAs, so a head the remote
has already moved past still counts as pushed. Advertised objects the checkout
does not have are ignored, which can only make the answer more cautious.

If git errors, times out, is missing, or returns something unparseable, the
verdict is **UNKNOWN**, not clean. A `dirty=0` produced by git falling over is
the most dangerous false negative a collector can have, so it is never treated
as a pass. The same applies to a subtree whose files could not all be read, and
to a candidate holding more than `--max-checkouts` repositories. `--offline`
extends this: a remote that is not a local path cannot be contacted, so its
checkout is UNKNOWN and kept.

A path with no git checkout in it falls back to age and budget only.

### The denylist

`~/.claude`, `~/ai-infra`, `~/github-projects`, and any path that names or
contains `profiles.db` or `corpus.db` can never be collected. These are
built in and cannot be switched off; `--protect PATH` and `AGENT_TRASH_PROTECT`
only add to them. Rule 1 is re-checked at the moment of deletion, not just
during planning. `/` and `$HOME` are refused as scan roots outright: name the
accumulation directories explicitly.

### Receipts

Every decision produces a receipt line carrying the path, apparent size, age,
reachability verdict, the evidence that produced that verdict (the git command,
its exit code, and what it said), the rule number, and collect or keep.
`--json` prints the whole run as one object; `--receipt PATH` appends it to a
JSONL audit log.

### Automating it

`gc` is a single deterministic command with no network calls of its own beyond
`git ls-remote`, so a cron entry or a launchd agent is enough. Start it in
report mode, read a few days of receipts, then add `--collect`:

```
0 3 * * *  agent-trash gc --roots ~/.claude-trash,~/worktrees --budget 5G --older-than 14 --receipt ~/.claude-trash/gc-receipts.jsonl
```

Verifying a large accumulation site is minutes of git calls, and a silent
scan is indistinguishable from a hang, so `--progress` names each candidate on
stderr as it is verified. It never touches stdout, so it is safe to combine
with `--json`.

A budget is about blocks on the disk, so sizes are allocated bytes
(`st_blocks * 512`) and a multiply-linked inode is counted once per candidate,
the way `du` does. This matters more than it sounds: `git clone` from a local
path hardlinks `.git/objects`, and a dump directory full of local clones reads
as more than twice its real size if those links are counted once per name,
which would make every reclaim estimate optimistic. The logical total is kept
alongside it as `apparent_size` in the JSON receipt.

An entry's age is measured from the newest mtime anywhere in its subtree, which
is the conservative choice: anything recently touched looks young and is
spared.

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

OpenClaw's native `before_tool_call` plugin hook blocks `exec` calls through
the self-contained adapter in `integrations/openclaw/`. It bridges
`event.params.command` to the canonical detector and fails closed if that
bridge cannot complete. No local Hermes Agent/client installation exposed a verified pre-tool interception API;
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
lifecycle, the `gc` decision ladder, and the quality rail's review range, in an
isolated temp directory.

The `gc` fixtures build real git repositories whose remotes are bare
repositories on the same disk, so `git ls-remote` is exercised for real and the
suite still needs no network. They pin the cases that matter: a clean pushed
repository is collectable, while a dirty tree, a stash, an unpushed commit, an
orphaned worktree whose git calls all fail, and a denylisted path are not.

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

Apache-2.0 — see [LICENSE](LICENSE).
