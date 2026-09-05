#!/usr/bin/env bash
# Installs the Claude adapter for agent-trash-guard:
#   1. symlinks agent-trash and the legacy claude-trash name into ~/.local/bin
#   2. registers hooks/trash_guard.py as a PreToolUse hook in ~/.claude/settings.json
# A timestamped backup of settings.json is written before any change.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

mkdir -p "$BIN_DIR"
ln -sf "$REPO_DIR/bin/claude-trash" "$BIN_DIR/claude-trash"
ln -sf "$REPO_DIR/bin/agent-trash" "$BIN_DIR/agent-trash"
echo "linked $BIN_DIR/agent-trash (plus compatibility alias claude-trash)"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH; add it to your shell profile" ;;
esac

mkdir -p "$(dirname "$SETTINGS")"
if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.backup.$(date +%Y%m%d%H%M%S)"
  echo "backed up $SETTINGS"
fi

python3 - "$SETTINGS" "$REPO_DIR" <<'PY'
import json, os, sys

settings_path, repo_dir = sys.argv[1], sys.argv[2]
hook_command = "python3 " + os.path.join(repo_dir, "hooks", "trash_guard.py")

settings = {}
if os.path.isfile(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)

pre_tool_use = settings.setdefault("hooks", {}).setdefault("PreToolUse", [])
for matcher in pre_tool_use:
    for hook in matcher.get("hooks", []):
        if "trash_guard.py" in hook.get("command", ""):
            print("hook already registered; settings unchanged")
            sys.exit(0)

pre_tool_use.append({
    "matcher": "Bash",
    "hooks": [{"type": "command", "command": hook_command}],
})
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print("registered PreToolUse hook in " + settings_path)
PY

echo "done. Restart any running Claude Code session to pick up the hook."
