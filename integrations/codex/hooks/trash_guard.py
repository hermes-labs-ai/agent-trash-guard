#!/usr/bin/env python3
"""Cross-agent hook: block permanent-delete commands and point to recoverable trash.

Reads a Claude/Codex PreToolUse or Gemini BeforeTool event on stdin. Exit 0
allows the tool call; exit 2 blocks it and feeds stderr back to the agent.
"""
import json
import os
import re
import shlex
import sys

DELETE_CMDS = {"rm", "unlink", "shred", "rmdir"}

# Shells whose `-c`/`eval` arguments are themselves shell source: a delete
# hidden inside one of these must be unwrapped and scanned as a new command,
# not treated as inert argument text.
SHELL_INTERPRETERS = {"bash", "sh", "zsh", "dash", "ksh", "ash"}

# Prefixes that pass command position through to the next real token without
# being a command themselves.
WRAPPER_CMDS = {"sudo", "command", "nohup", "time"}
KEYWORDS = {"then", "do", "else", "elif"}

# Characters that separate shell statements/command groups. A token made up
# entirely of these characters (`;`, `&`, `&&`, `(`, `)`, `{`, `}`, a
# backtick, or a literal newline) marks the *next* token as command position.
OPERATOR_CHARS = ";&|(){}`\n"
OPERATOR_TOKEN = re.compile(r"^[" + re.escape(OPERATOR_CHARS) + r"]+$")
ENV_ASSIGNMENT = re.compile(r"^\w+=")

FIND_DELETE = re.compile(r"\bfind\b[^;&|]*\s-delete\b")
FIND_EXEC_DELETE = re.compile(
    r"-(?:exec|execdir|ok|okdir)\s+"
    r"(?:(?:/[A-Za-z0-9_.+-]+)*/)?(?:rm|shred|unlink)\b"
)
GIT_CLEAN_FORCE = re.compile(r"\bgit\s+clean\b[^;&|]*\s-\w*f")

# Fallback used only when a command can't be tokenized (e.g. unbalanced
# quotes). Deliberately conservative/raw: it scans unmasked text, the same
# way this hook always did before quote-aware tokenizing existed, so a
# malformed string still gets caught rather than silently passed.
LEGACY_COMMAND_POSITION = re.compile(
    r"(?:^|[;&|(){}]|\$\(|`|\n)\s*"
    r"(?:(?:sudo|command|nohup|time|then|do|else|elif)\s+|env\s+(?:\w+=\S*\s+)*|xargs\s+(?:-\S+\s+)*)*"
    r"([A-Za-z0-9_./-]+)"
)

MAX_UNWRAP_DEPTH = 8


def _tokenize(command):
    """Shell-aware tokenizer: quotes group into single (dequoted) words,
    operators split out as their own tokens even when unquoted and
    unspaced, and quoted content is left completely alone."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=OPERATOR_CHARS)
    lexer.whitespace_split = True
    lexer.whitespace = " \t\r"
    lexer.commenters = ""
    try:
        return list(lexer)
    except ValueError:
        return None


def _is_operator(token):
    return bool(OPERATOR_TOKEN.match(token))


def _resolve_head(tokens, start):
    """Walk past wrapper prefixes (sudo/command/nohup/time, env VAR=val...,
    xargs [-flags]) to the token that is actually executed. Returns the
    index of that token, or None if the statement runs out first."""
    i, n = start, len(tokens)
    while i < n:
        tok = tokens[i]
        if tok in WRAPPER_CMDS:
            i += 1
            continue
        if tok == "env":
            i += 1
            while i < n and ENV_ASSIGNMENT.match(tokens[i]):
                i += 1
            continue
        if tok == "xargs":
            i += 1
            while i < n and tokens[i].startswith("-") and not _is_operator(tokens[i]):
                i += 1
            continue
        break
    return i if i < n else None


def _interpreter_code(tokens, head_idx):
    """If `head_idx` is `bash|sh|zsh|dash|ksh|ash` invoked with a `-c`-style
    flag (including combined short flags like `-lc`), return the single
    token holding the code it will execute. Flags that don't select `-c`
    mode are skipped; a bare script-file invocation (`bash script.sh`)
    yields no code to unwrap."""
    j = head_idx + 1
    n = len(tokens)
    while j < n:
        tok = tokens[j]
        if _is_operator(tok):
            return None
        if tok.startswith("--"):
            j += 1
            continue
        if tok.startswith("-") and len(tok) > 1:
            if "c" in tok[1:]:
                if j + 1 < n and not _is_operator(tokens[j + 1]):
                    return tokens[j + 1]
                return None
            j += 1
            continue
        return None
    return None


def _eval_code(tokens, head_idx):
    """`eval` runs the shell-word-joined concatenation of all its remaining
    arguments (through the end of the statement) as new shell source. This
    is true whether those arguments arrived as one quoted string
    (`eval "rm -rf x"`) or several bare words (`eval rm -rf x`)."""
    j = head_idx + 1
    parts = []
    n = len(tokens)
    while j < n and not _is_operator(tokens[j]):
        parts.append(tokens[j])
        j += 1
    return " ".join(parts) if parts else None


def _check_candidate(tokens, idx, depth):
    head_idx = _resolve_head(tokens, idx)
    if head_idx is None:
        return None
    head = tokens[head_idx]
    base = os.path.basename(head)
    if base in DELETE_CMDS:
        return base
    if depth >= MAX_UNWRAP_DEPTH:
        return "max-nesting-depth"
    if base in SHELL_INTERPRETERS:
        code = _interpreter_code(tokens, head_idx)
        if code is not None:
            return find_violation(code, depth + 1)
        return None
    if head == "eval":
        code = _eval_code(tokens, head_idx)
        if code is not None:
            return find_violation(code, depth + 1)
        return None
    return None


def _scan_tokens(tokens, depth):
    if not tokens:
        return None
    candidates = {0}
    for i, tok in enumerate(tokens):
        if _is_operator(tok) or tok in KEYWORDS:
            candidates.add(i + 1)
    for idx in sorted(candidates):
        if idx >= len(tokens):
            continue
        found = _check_candidate(tokens, idx, depth)
        if found:
            return found
    return None


def find_violation(command, depth=0):
    tokens = _tokenize(command)
    if tokens is None:
        # Unparseable quoting: fall back to the old raw-text scan rather
        # than silently allowing an unparseable command through.
        for match in LEGACY_COMMAND_POSITION.finditer(command):
            token = os.path.basename(match.group(1))
            if token in DELETE_CMDS:
                return token
    else:
        found = _scan_tokens(tokens, depth)
        if found:
            return found
    if FIND_DELETE.search(command):
        return "find -delete"
    if FIND_EXEC_DELETE.search(command):
        return "find -exec rm"
    if GIT_CLEAN_FORCE.search(command):
        return "git clean -f"
    return None


def main():
    try:
        event = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    if event.get("tool_name") not in {"Bash", "run_shell_command"}:
        sys.exit(0)
    command = (event.get("tool_input") or {}).get("command", "")
    if not command:
        sys.exit(0)
    if os.environ.get("TRASH_GUARD_ALLOW") == "1" or re.search(
        r"\bTRASH_GUARD_ALLOW=1\b", command
    ):
        sys.exit(0)
    violation = find_violation(command)
    if violation is None:
        sys.exit(0)
    # Marketplace and extension installs run from private copies. Prefer an
    # explicit host root when available, then derive the self-contained bundle
    # root so Gemini never relies on a global PATH symlink.
    plugin_root = (
        os.environ.get("AGENT_TRASH_GUARD_ROOT")
        or os.environ.get("PLUGIN_ROOT")
        or os.environ.get("CLAUDE_PLUGIN_ROOT")
        or os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    )
    trash_command = '"{}"'.format(os.path.join(plugin_root, "bin", "agent-trash"))
    sys.stderr.write(
        "trash-guard: blocked a permanent delete ({0}).\n"
        "Command: {1}\n"
        "Move the targets to recoverable trash instead:\n"
        "  {2} put <path...>\n"
        "Inspect or undo later:\n"
        "  {2} list\n"
        "  {2} restore <id>\n"
        "  {2} empty --older-than 7 --yes\n"
        "If the user explicitly approved a permanent delete, prefix the "
        "command with TRASH_GUARD_ALLOW=1 for a one-off override.\n".format(
            violation, command[:200], trash_command
        )
    )
    sys.exit(2)


if __name__ == "__main__":
    main()
