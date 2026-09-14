# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in agent-trash-guard — including a
delete pattern that the guard fails to block, or a flaw in how the trash
directory is written to or restored from — please report it responsibly.

**Do not open a public issue for security vulnerabilities.**

Instead, email us at: **roli@hermes-labs.ai**

Include:
- A description of the vulnerability.
- Steps to reproduce the issue.
- Any relevant logs or output.

## Response Timeline

- **Acknowledgment**: Within 48 hours of your report.
- **Assessment**: Within 7 days we will confirm the issue and outline next steps.
- **Fix**: We aim to release a patch within 30 days of confirmation.

This is a solo-maintained project. These are the response times we aim for,
not a contractual SLA, and there is no bug bounty program.

## Scope

In scope: the hook's delete-pattern detection (`hooks/trash_guard.py`), the
`agent-trash` CLI's put/list/restore/empty commands, and the generated
runtime copies under `integrations/claude/` and `integrations/codex/`.

Out of scope by design, and not a vulnerability report: the `TRASH_GUARD_ALLOW=1`
escape hatch (it is intentionally visible and bypasses the guard on purpose),
and delete patterns not yet covered by v0.1 (overwrites and truncations — see
the README's "What gets blocked" section for the current pattern list).

## Supported Versions

Security updates are applied to the latest release only.

Thank you for helping keep agent-trash-guard safe.
