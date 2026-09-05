#!/usr/bin/env bash
set -euo pipefail

SETTINGS="${GEMINI_SETTINGS:-$HOME/.gemini/settings.json}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
REPO_DIR="${AGENT_TRASH_GUARD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

if [ -L "$BIN_DIR/agent-trash" ] && python3 - "$BIN_DIR/agent-trash" "$REPO_DIR/bin/agent-trash" <<'PY'
import os
import sys
raise SystemExit(0 if os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]) else 1)
PY
then
  rm "$BIN_DIR/agent-trash"
elif [ -e "$BIN_DIR/agent-trash" ] || [ -L "$BIN_DIR/agent-trash" ]; then
  echo "left non-owned path unchanged: $BIN_DIR/agent-trash"
fi

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.backup.$(date +%Y%m%d%H%M%S)"
  python3 - "$SETTINGS" "$REPO_DIR" <<'PY'
import json
import os
import shlex
import sys

settings_path, repo_dir = sys.argv[1], sys.argv[2]
with open(settings_path) as handle:
    settings = json.load(handle)
template_path = os.path.join(repo_dir, "integrations", "gemini", "hooks.json")
with open(template_path) as handle:
    template = json.load(handle)
owned_hook = template["hooks"]["BeforeTool"][0]["hooks"][0]
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


groups = settings.get("hooks", {}).get("BeforeTool", [])
kept = []
for group in groups:
    group["hooks"] = [
        hook for hook in group.get("hooks", [])
        if not is_owned(hook)
    ]
    if group["hooks"]:
        kept.append(group)
if kept:
    settings["hooks"]["BeforeTool"] = kept
elif "BeforeTool" in settings.get("hooks", {}):
    del settings["hooks"]["BeforeTool"]
with open(settings_path, "w") as handle:
    json.dump(settings, handle, indent=2)
    handle.write("\n")
PY
fi

echo "removed Gemini adapter; trash contents were not touched."
