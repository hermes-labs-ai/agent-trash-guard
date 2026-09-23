#!/usr/bin/env python3
"""Cursor beforeShellExecution adapter for the canonical trash detector."""
import json
import os
import re
import sys

from trash_guard import find_violation


def has_command_override(command):
    match = re.match(r"^[ \t]*TRASH_GUARD_ALLOW=1[ \t]+", command)
    if match is None:
        return False
    remainder = command[match.end():]
    return bool(remainder.strip()) and not any(char in remainder for char in ";&|`$\r\n")


def decide(event):
    command = event.get("command")
    if not isinstance(command, str):
        return {"permission": "deny", "user_message": "Trash Guard could not inspect the shell command."}
    if os.environ.get("TRASH_GUARD_ALLOW") == "1" or has_command_override(command):
        return {"permission": "allow"}
    violation = find_violation(command)
    if violation is None:
        return {"permission": "allow"}
    root = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    trash = os.path.join(root, "bin", "agent-trash")
    message = (
        "Trash Guard blocked a permanent delete ({0}). Use '{1} put <path...>' "
        "for recoverable deletion; '{1} list' and '{1} restore <id>' undo it. "
        "If the user explicitly approved a permanent delete, prefix that command "
        "with TRASH_GUARD_ALLOW=1."
    ).format(violation, trash)
    return {"permission": "deny", "user_message": message, "agent_message": message}


def main():
    try:
        event = json.load(sys.stdin)
        if not isinstance(event, dict):
            raise ValueError("event must be an object")
        result = decide(event)
    except Exception:
        result = {"permission": "deny", "user_message": "Trash Guard could not inspect the shell command."}
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
