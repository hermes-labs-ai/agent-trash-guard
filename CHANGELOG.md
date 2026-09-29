# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

`0.1.4` is the first entry recorded here; earlier releases predate this file.

## [Unreleased]

### Known issues (planned for 0.1.5)

- `gc --roots <checkout>/.git` can still collect the internals of a `.git`
  directory passed as the root. The atomic judgment covers the checkout
  itself, not its `.git` dir handed over directly.
- Submodule state is judged per nested checkout, but `checkout_reachability`
  on the toplevel alone cannot see unpushed commits inside a submodule; the
  nested judgment (added in 0.1.4) covers the common shapes.

## [0.1.4] - 2026-09-29

Patch release. The headline fix: `gc` could shred a live git checkout passed
as a scan root — it no longer can. All changes are backwards-compatible bug
fixes and docs; the CLI surface and hook contract are otherwise unchanged.

### Fixed

- `gc` now treats a git checkout passed as a scan root as one atomic unit and
  never splits it into parts — and nested checkouts inside that root are
  judged too, so a gitignored nested repo (or submodule) with unpushed work
  keeps the whole root. Previously `gc --roots <checkout>` could delete
  uncommitted work and unpushed commits — the exact failure this product
  exists to prevent. Adversarially re-verified: dirty worktree, unpushed
  commit, stash, deleted-remote, gitignored nested repo, and submodule
  fixtures all survive `--collect` with 0 bytes reclaimed.
- `uninstall.sh` now restores `~/.claude/settings.json` from the timestamped
  install-time backup (oldest first), so your pre-existing settings — including
  unrelated hooks — come back intact. Install-time backups are consumed on
  uninstall instead of accumulating.
- The hook's block message now names the installed `agent-trash put <path...>`
  command on `PATH` instead of a repo-internal absolute path that doesn't
  exist on a user's machine.
- `install.sh` prints the exact `export PATH=".../.local/bin:$PATH"` line to
  run when `~/.local/bin` isn't on `PATH`, and install-time backup filenames
  are now unique per install.

### Changed

- README Install section leads with the `./install.sh` one-liner as the
  recommended path; the plugin-matrix wayfinding is no longer the first
  thing a new user sees.
