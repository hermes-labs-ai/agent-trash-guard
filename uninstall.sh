#!/usr/bin/env bash
# Reverses install.sh: removes the PreToolUse hook entry and the CLI symlink.
# Trash contents under ~/.claude-trash are left in place.
set -euo pipefail

SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

remove_owned_link() {
  local path="$1" target="$2"
  if [ -L "$path" ] && python3 - "$path" "$target" <<'PY'
import os
import sys
raise SystemExit(0 if os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]) else 1)
PY
  then
    rm "$path"
    echo "removed $path"
  elif [ -e "$path" ] || [ -L "$path" ]; then
    echo "left non-owned path unchanged: $path"
  fi
}

remove_owned_link "$BIN_DIR/claude-trash" "$REPO_DIR/bin/claude-trash"
remove_owned_link "$BIN_DIR/agent-trash" "$REPO_DIR/bin/agent-trash"

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.backup.$(date +%Y%m%d%H%M%S)"
python3 - "$SETTINGS" "$REPO_DIR" <<'PY'
import json, os, sys

settings_path, repo_dir = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    settings = json.load(f)

# The root-hook path is the pre-plugin installer location. Keep this narrow:
# a separately installed or foreign trash_guard.py must remain untouched.
owned_commands = {
    "python3 " + os.path.join(repo_dir, "hooks", "trash_guard.py"),
    "python3 " + os.path.join(
        repo_dir, "integrations", "claude", "hooks", "trash_guard.py"
    ),
}

pre_tool_use = settings.get("hooks", {}).get("PreToolUse", [])
kept = []
for matcher in pre_tool_use:
    matcher["hooks"] = [
        h for h in matcher.get("hooks", [])
        if h.get("command", "") not in owned_commands
    ]
    if matcher["hooks"]:
        kept.append(matcher)

if kept:
    settings["hooks"]["PreToolUse"] = kept
elif "PreToolUse" in settings.get("hooks", {}):
    del settings["hooks"]["PreToolUse"]

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print("removed trash-guard hook from " + settings_path)
PY
fi

echo "done. Your trash directory was not touched."
