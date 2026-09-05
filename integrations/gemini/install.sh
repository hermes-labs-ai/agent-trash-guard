#!/usr/bin/env bash
# Install the native Gemini CLI BeforeTool adapter without touching Claude settings.
set -euo pipefail

REPO_DIR="${AGENT_TRASH_GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
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
import shlex
import sys

settings_path, repo_dir = sys.argv[1], sys.argv[2]
settings = {}
if os.path.isfile(settings_path):
    with open(settings_path) as handle:
        settings = json.load(handle)

template_path = os.path.join(repo_dir, "integrations", "gemini", "hooks.json")
with open(template_path) as handle:
    template = json.load(handle)
owned_group = template["hooks"]["BeforeTool"][0]
owned_hook = owned_group["hooks"][0]
hook_path = os.path.join(repo_dir, "hooks", "trash_guard.py")
owned_hook["command"] = owned_hook["command"].replace(
    "__AGENT_TRASH_GUARD_ROOT__/hooks/trash_guard.py", shlex.quote(hook_path)
)


def is_owned(hook):
    return (
        hook.get("name") == owned_hook["name"]
        and hook.get("type") == owned_hook["type"]
        and hook.get("command") == owned_hook["command"]
    )

groups = settings.setdefault("hooks", {}).setdefault("BeforeTool", [])
for group in groups:
    for hook in group.get("hooks", []):
        if is_owned(hook):
            print("Gemini hook already registered; settings unchanged")
            raise SystemExit(0)

groups.append(owned_group)
with open(settings_path, "w") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
print("registered BeforeTool hook in " + settings_path)
PY

echo "linked $BIN_DIR/agent-trash"
echo "done. Restart Gemini CLI to pick up the hook."
