# Contributing to agent-trash-guard

Thank you for your interest in contributing to agent-trash-guard.

## Reporting Bugs

- Search [existing issues](https://github.com/hermes-labs-ai/agent-trash-guard/issues) first to avoid duplicates.
- Open a new issue with a clear title and description.
- Include steps to reproduce, expected behavior, and actual behavior — a
  sample command line and which host (Claude Code, Codex CLI, Gemini CLI, or
  the manual fallback) is usually enough to reproduce a hook issue.

## Submitting Pull Requests

1. Fork the repository.
2. Create a feature branch from `main` (`git checkout -b my-feature`).
3. Make your changes with clear, focused commits.
4. If you touch `hooks/trash_guard.py`, `bin/`, `lib/`, or anything under
   `integrations/claude/` or `integrations/codex/`, regenerate the platform
   bundles rather than hand-editing the generated copies:
   ```bash
   python3 tools/build_platform_bundles.py
   python3 tools/build_platform_bundles.py --check
   ```
5. Run the test suite before submitting:
   ```bash
   ./tests/run.sh
   ./tests/recoverability-demo.sh
   ```
6. Open a pull request against `main` with a clear description of the change.

## Code Style

The project has no dependencies beyond Python 3 (stdlib only) and bash, and
no enforced formatter. Match the existing style in the file you are editing.

## Testing

- `./tests/run.sh` covers the hook's block/allow matrix, the full
  put/list/restore/empty lifecycle, and the quality rail's review range.
- `./tests/recoverability-demo.sh` is a self-contained, deterministic proof
  that a blocked delete and a full trash round-trip lose nothing.
- `python3 .hermes/hermes_gate_runner.py full --all` runs the same Hermes
  Gate quality rail that CI runs.

## Development Setup

```bash
git clone https://github.com/hermes-labs-ai/agent-trash-guard.git
cd agent-trash-guard
./tests/run.sh
```

No install step is required to run the tests — the project has no
dependencies beyond Python 3 (stdlib only) and bash.

## Questions?

Open an issue or start a discussion on the repository.
