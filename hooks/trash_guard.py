#!/usr/bin/env python3
"""PreToolUse hook for Claude Code: block permanent-delete commands, point to `claude-trash put`.

Reads the PreToolUse event JSON on stdin. Exit 0 allows the tool call;
exit 2 blocks it and feeds stderr back to Claude as guidance.
"""
import json
import os
import re
import sys

DELETE_CMDS = {"rm", "unlink", "shred", "rmdir"}

# A token in command position: start of input, or after ; & | && || newline,
# subshell/backtick/paren/brace, optionally preceded by common wrappers or
# shell keywords (then/do/else/elif) that introduce a new command.
COMMAND_POSITION = re.compile(
    r"(?:^|[;&|(){}]|\$\(|`|\n)\s*"
    r"(?:(?:sudo|command|nohup|time|then|do|else|elif)\s+|env\s+(?:\w+=\S*\s+)*|xargs\s+(?:-\S+\s+)*)*"
    r"([A-Za-z0-9_./-]+)"
)

FIND_DELETE = re.compile(r"\bfind\b[^;&|]*\s-delete\b")
FIND_EXEC_DELETE = re.compile(
    r"-(?:exec|execdir|ok|okdir)\s+"
    r"(?:(?:/[A-Za-z0-9_.+-]+)*/)?(?:rm|shred|unlink)\b"
)
GIT_CLEAN_FORCE = re.compile(r"\bgit\s+clean\b[^;&|]*\s-\w*f")


def find_violation(command):
    for match in COMMAND_POSITION.finditer(command):
        token = os.path.basename(match.group(1))
        if token in DELETE_CMDS:
            return token
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
    if event.get("tool_name") != "Bash":
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
    plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
    if plugin_root:
        trash_command = '"{}"'.format(os.path.join(plugin_root, "bin", "claude-trash"))
    else:
        trash_command = "claude-trash"
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
