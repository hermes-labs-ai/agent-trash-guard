#!/usr/bin/env bash
# Install the native Gemini CLI BeforeTool adapter without touching Claude settings.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETTINGS="${GEMINI_SETTINGS:-$HOME/.gemini/settings.json}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

mkdir -p "$BIN_DIR" "$(dirname "$SETTINGS")"
if [ -e "$BIN_DIR/agent-trash" ] || [ -L "$BIN_DIR/agent-trash" ]; then
  if ! { [ -L "$BIN_DIR/agent-trash" ] && python3 - "$BIN_DIR/agent-trash" "$REPO_DIR/bin/agent-trash" <<'PY'
import os
import sys
raise SystemExit(0 if os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]) else 1)
PY
  }
  then
    echo "refusing to replace non-owned path: $BIN_DIR/agent-trash" >&2
    exit 1
  fi
else
  ln -s "$REPO_DIR/bin/agent-trash" "$BIN_DIR/agent-trash"
fi

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.backup.$(date +%Y%m%d%H%M%S)"
fi

python3 - "$SETTINGS" "$REPO_DIR" <<'PY'
import json
import os
import sys

settings_path, repo_dir = sys.argv[1], sys.argv[2]
settings = {}
if os.path.isfile(settings_path):
    with open(settings_path) as handle:
        settings = json.load(handle)

groups = settings.setdefault("hooks", {}).setdefault("BeforeTool", [])
command = "python3 " + os.path.join(repo_dir, "hooks", "trash_guard.py")
for group in groups:
    for hook in group.get("hooks", []):
        if hook.get("name") == "agent-trash-guard":
            print("Gemini hook already registered; settings unchanged")
            raise SystemExit(0)

groups.append({
    "matcher": "run_shell_command",
    "hooks": [{
        "name": "agent-trash-guard",
        "type": "command",
        "command": command,
        "timeout": 8,
        "description": "Block permanent deletes and recommend recoverable trash",
    }],
})
with open(settings_path, "w") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
print("registered BeforeTool hook in " + settings_path)
PY

echo "linked $BIN_DIR/agent-trash"
echo "done. Restart Gemini CLI to pick up the hook."
