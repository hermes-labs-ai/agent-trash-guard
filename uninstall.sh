#!/usr/bin/env bash
# Reverses install.sh: restores ~/.claude/settings.json from the timestamped
# backup install.sh wrote, and removes the CLI symlinks it created.
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
  # A rollback snapshot of the current file, with a name that can never
  # clobber an existing backup (two runs in the same second must not
  # overwrite each other).
  BACKUP_BASE="$SETTINGS.backup.$(date +%Y%m%d%H%M%S)"
  PRE_UNINSTALL="$BACKUP_BASE"
  n=0
  while [ -e "$PRE_UNINSTALL" ] || [ -L "$PRE_UNINSTALL" ]; do
    n=$((n + 1))
    PRE_UNINSTALL="$BACKUP_BASE-$n"
  done
  cp "$SETTINGS" "$PRE_UNINSTALL"
  echo "backed up $SETTINGS"

  # The oldest install-time backup is the pre-install state: later backups
  # were taken after our hook was already registered.
  OLDEST_BACKUP=""
  for candidate in "$SETTINGS".backup.*; do
    [ -e "$candidate" ] || continue
    [ "$candidate" = "$PRE_UNINSTALL" ] && continue
    if [ -z "$OLDEST_BACKUP" ] || [[ "$candidate" < "$OLDEST_BACKUP" ]]; then
      OLDEST_BACKUP="$candidate"
    fi
  done

  if [ -n "$OLDEST_BACKUP" ]; then
    cp "$OLDEST_BACKUP" "$SETTINGS"
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SETTINGS"
    echo "restored $SETTINGS from $OLDEST_BACKUP"
    # The backups have done their job: the settings are byte-identical to the
    # pre-install state, so consume them rather than leaving stale snapshots
    # that a later install could mistake for its own.
    rm -f "$SETTINGS".backup.*
    echo "removed install-time settings backups"
  else
    # No backup: install.sh created this file from scratch (or the backups
    # were deleted by hand). Strip our hook in place instead.
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

if settings == {"hooks": {}}:
    # Nothing in this file predates install.sh: it created the file, so
    # removing it is the true restore.
    os.remove(settings_path)
    print("removed " + settings_path + " (created by install.sh)")
else:
    print("removed trash-guard hook from " + settings_path)
PY
  if [ ! -f "$SETTINGS" ]; then
    # The file install.sh created is gone; its rollback snapshot goes with it.
    rm -f "$PRE_UNINSTALL"
  fi
  fi
fi

echo "done. Your trash directory was not touched."
