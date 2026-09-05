#!/usr/bin/env bash
# Reverses install.sh: removes the PreToolUse hook entry and the CLI symlink.
# Trash contents under ~/.claude-trash are left in place.
set -euo pipefail

SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

if [ -L "$BIN_DIR/claude-trash" ]; then
  rm "$BIN_DIR/claude-trash"
  echo "removed $BIN_DIR/claude-trash"
fi
if [ -L "$BIN_DIR/agent-trash" ]; then
  rm "$BIN_DIR/agent-trash"
  echo "removed $BIN_DIR/agent-trash"
fi

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.backup.$(date +%Y%m%d%H%M%S)"
  python3 - "$SETTINGS" <<'PY'
import json, sys

settings_path = sys.argv[1]
with open(settings_path) as f:
    settings = json.load(f)

pre_tool_use = settings.get("hooks", {}).get("PreToolUse", [])
kept = []
for matcher in pre_tool_use:
    matcher["hooks"] = [
        h for h in matcher.get("hooks", [])
        if "trash_guard.py" not in h.get("command", "")
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
