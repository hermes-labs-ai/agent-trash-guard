#!/usr/bin/env bash
set -u
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_DIR/hooks/trash_guard.py"
CLI="$REPO_DIR/bin/agent-trash"
LEGACY_CLI="$REPO_DIR/bin/claude-trash"
WORK="$(mktemp -d)"
export CLAUDE_TRASH_DIR="$WORK/trash"
unset TRASH_GUARD_ALLOW
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "PASS  $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL  $name (expected $expected, got $actual)"
  fi
}

hook_exit() {
  printf '%s' "$1" | python3 "$HOOK" 2>/dev/null
  echo $?
}

exists_exit() {
  if [ -e "$1" ]; then echo 0; else echo 1; fi
}

nonempty_exit() {
  if [ -n "$1" ]; then echo 0; else echo 1; fi
}

bash_event() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

gemini_event() {
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"BeforeTool","tool_name":"run_shell_command","tool_input":{"command":sys.argv[1]}}))' "$1"
}

# --- hook: blocks delete commands ---
check "hook blocks rm"              2 "$(hook_exit "$(bash_event 'rm -rf build')")"
check "hook blocks chained rm"      2 "$(hook_exit "$(bash_event 'make && rm -f out.log')")"
check "hook blocks xargs rm"        2 "$(hook_exit "$(bash_event 'ls *.tmp | xargs rm')")"
check "hook blocks sudo rm"         2 "$(hook_exit "$(bash_event 'sudo rm /etc/thing')")"
check "hook blocks find -delete"    2 "$(hook_exit "$(bash_event 'find . -name "*.pyc" -delete')")"
check "hook blocks find -exec rm"   2 "$(hook_exit "$(bash_event 'find . -name x -exec rm {} \;')")"
check "hook blocks find -exec /bin/rm" 2 "$(hook_exit "$(bash_event 'find . -name x -exec /bin/rm {} \;')")"
check "hook blocks find -execdir absolute unlink" 2 "$(hook_exit "$(bash_event 'find . -name x -execdir /usr/bin/unlink {} \;')")"
check "hook blocks find -ok absolute rm" 2 "$(hook_exit "$(bash_event 'find . -name x -ok /bin/rm {} \;')")"
check "hook blocks find -okdir absolute unlink" 2 "$(hook_exit "$(bash_event 'find . -name x -okdir /usr/bin/unlink {} \;')")"
check "hook blocks git clean -fd"   2 "$(hook_exit "$(bash_event 'git clean -fd')")"
check "hook blocks unlink"          2 "$(hook_exit "$(bash_event 'unlink ./link')")"
check "hook blocks shred"           2 "$(hook_exit "$(bash_event 'shred -u secret.txt')")"
check "hook blocks absolute rm"     2 "$(hook_exit "$(bash_event '/bin/rm -rf build')")"
check "hook blocks rm after then"   2 "$(hook_exit "$(bash_event 'if true; then rm -rf x; fi')")"
check "hook blocks rm after do"     2 "$(hook_exit "$(bash_event 'for f in *; do rm -f x; done')")"
check "hook blocks rm after else"   2 "$(hook_exit "$(bash_event 'if true; then echo hi; else rm -rf x; fi')")"
check "hook blocks rm in parens"    2 "$(hook_exit "$(bash_event '( rm -rf x )')")"
check "hook blocks rm in braces"    2 "$(hook_exit "$(bash_event '{ rm -rf x; }')")"
check "Gemini hook blocks rm"       2 "$(hook_exit "$(gemini_event 'rm -rf build')")"
check "Gemini hook allows ls"       0 "$(hook_exit "$(gemini_event 'ls -la')")"

# --- hook: allows everything else ---
check "hook allows ls"              0 "$(hook_exit "$(bash_event 'ls -la')")"
check "hook allows rm as word"      0 "$(hook_exit "$(bash_event 'echo rm is just a word')")"
check "hook allows rm-suffix cmd"   0 "$(hook_exit "$(bash_event 'npm run charm')")"
check "hook allows git rm"          0 "$(hook_exit "$(bash_event 'git rm --cached file.txt')")"
check "hook allows git clean -n"    0 "$(hook_exit "$(bash_event 'git clean -n')")"
check "hook allows find -exec absolute printf" 0 "$(hook_exit "$(bash_event 'find . -name x -exec /usr/bin/printf "%s\\n" {} \;')")"
check "hook allows override prefix" 0 "$(hook_exit "$(bash_event 'TRASH_GUARD_ALLOW=1 rm -rf build')")"
check "hook ignores non-Bash tool"  0 "$(hook_exit '{"tool_name":"Read","tool_input":{"file_path":"/x"}}')"
check "hook ignores bad json"       0 "$(hook_exit 'not json at all')"
printf '%s' "$(bash_event 'rm -rf build')" | TRASH_GUARD_ALLOW=1 python3 "$HOOK" 2>/dev/null
check "hook allows env override"    0 "$?"

# --- native plugin: discovery metadata and plugin-relative guidance ---
python3 - "$REPO_DIR" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / ".claude-plugin" / "plugin.json").read_text())
assert manifest["name"] == "claude-trash-guard"
assert manifest["version"] == "0.1.0"
marketplace = json.loads((root / ".claude-plugin" / "marketplace.json").read_text())
marketplace_entry = marketplace["plugins"][0]
assert marketplace["name"] == "hermes-labs"
assert marketplace_entry["name"] == manifest["name"]
assert marketplace_entry["version"] == manifest["version"]
assert marketplace_entry["source"] == "./"
hooks = json.loads((root / "hooks" / "hooks.json").read_text())
entry = hooks["hooks"]["PreToolUse"][0]
assert entry["matcher"] == "Bash"
command = entry["hooks"][0]
assert command["command"] == "python3"
assert command["args"] == ["${CLAUDE_PLUGIN_ROOT}/hooks/trash_guard.py"]

codex = json.loads((root / ".codex-plugin" / "plugin.json").read_text())
assert codex["name"] == "agent-trash-guard"
assert codex["hooks"] == "./hooks/codex.json"
codex_hooks = json.loads((root / "hooks" / "codex.json").read_text())
codex_entry = codex_hooks["hooks"]["PreToolUse"][0]
assert codex_entry["matcher"] == "Bash"
assert codex_entry["hooks"][0]["command"] == "python3 ${PLUGIN_ROOT}/hooks/trash_guard.py"

codex_market = json.loads((root / ".agents" / "plugins" / "marketplace.json").read_text())
assert codex_market["plugins"][0]["name"] == "agent-trash-guard"

gemini = json.loads((root / "integrations" / "gemini" / "hooks.json").read_text())
gemini_entry = gemini["hooks"]["BeforeTool"][0]
assert gemini_entry["matcher"] == "run_shell_command"
PY
check "adapter metadata is valid JSON" 0 "$?"

PLUGIN_ERR="$({
  printf '%s' "$(bash_event 'rm -rf build')" |
    CLAUDE_PLUGIN_ROOT="$REPO_DIR" python3 "$HOOK" 2>&1 >/dev/null
} || true)"
printf '%s' "$PLUGIN_ERR" | grep -Fq "\"$REPO_DIR/bin/agent-trash\" put <path...>"
check "plugin guidance uses bundled CLI" 0 "$?"

python3 "$LEGACY_CLI" --help 2>&1 | grep -q "agent-trash"
check "legacy claude-trash command remains compatible" 0 "$?"

# --- Gemini installer: isolated registration and removal ---
GEMINI_SETTINGS="$WORK/gemini/settings.json" BIN_DIR="$WORK/bin" \
  "$REPO_DIR/integrations/gemini/install.sh" >/dev/null
python3 - "$WORK/gemini/settings.json" "$REPO_DIR" <<'PY'
import json
import pathlib
import sys
settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
entry = settings["hooks"]["BeforeTool"][0]
assert entry["matcher"] == "run_shell_command"
assert entry["hooks"][0]["command"] == f"python3 {sys.argv[2]}/hooks/trash_guard.py"
PY
check "Gemini installer registers native hook" 0 "$?"
GEMINI_SETTINGS="$WORK/gemini/settings.json" BIN_DIR="$WORK/bin" \
  "$REPO_DIR/integrations/gemini/uninstall.sh" >/dev/null
python3 - "$WORK/gemini/settings.json" <<'PY'
import json
import pathlib
import sys
settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert not settings.get("hooks", {}).get("BeforeTool")
PY
check "Gemini uninstaller removes native hook" 0 "$?"

# --- cli: put / list / restore roundtrip ---
mkdir -p "$WORK/project/sub"
echo "keep me" > "$WORK/project/a.txt"
echo "nested"  > "$WORK/project/sub/b.txt"

python3 "$CLI" put "$WORK/project/a.txt" "$WORK/project/sub/b.txt" > "$WORK/put.out"
check "put exits 0" 0 "$?"
check "put removed a.txt from origin" 1 "$(exists_exit "$WORK/project/a.txt")"
check "put removed b.txt from origin" 1 "$(exists_exit "$WORK/project/sub/b.txt")"

ENTRY_ID="$(python3 "$CLI" list | head -1 | awk '{print $1}')"
check "list shows one entry" 0 "$(nonempty_exit "$ENTRY_ID")"
python3 "$CLI" list | grep -q "a.txt"
check "list shows original path" 0 "$?"

python3 "$CLI" restore "$ENTRY_ID" > /dev/null
check "restore exits 0" 0 "$?"
check "restore returned a.txt" 0 "$(exists_exit "$WORK/project/a.txt")"
check "restore returned b.txt" 0 "$(exists_exit "$WORK/project/sub/b.txt")"
check "restore content intact" "keep me" "$(cat "$WORK/project/a.txt")"
check "restored entry removed" 1 "$(python3 "$CLI" list | grep -c 'trash is empty')"

# --- cli: restore refuses to overwrite without --force ---
echo "victim" > "$WORK/project/c.txt"
python3 "$CLI" put "$WORK/project/c.txt" > /dev/null
echo "newer file" > "$WORK/project/c.txt"
ENTRY_ID="$(python3 "$CLI" list | head -1 | awk '{print $1}')"
python3 "$CLI" restore "$ENTRY_ID" 2>/dev/null
check "restore refuses overwrite" 1 "$?"
check "existing file untouched" "newer file" "$(cat "$WORK/project/c.txt")"
python3 "$CLI" restore "$ENTRY_ID" --force > /dev/null
check "restore --force exits 0" 0 "$?"
check "restore --force wins" "victim" "$(cat "$WORK/project/c.txt")"

# --- cli: empty requires --yes, respects age ---
echo "old" > "$WORK/project/d.txt"
python3 "$CLI" put "$WORK/project/d.txt" > /dev/null
python3 "$CLI" empty 2>/dev/null
check "empty without --yes refuses" 1 "$?"
python3 "$CLI" empty --older-than 1 --yes | grep -q "removed 0"
check "empty spares young entries" 0 "$?"
# two entries remain: the fresh d.txt entry plus the c.txt entry, which
# survives restore because --force parks the displaced file inside it
python3 "$CLI" empty --older-than 0 --yes | grep -q "removed 2"
check "empty purges old entries" 0 "$?"

echo
echo "$PASS passed, $FAIL failed"
rm -rf "$WORK"
[ "$FAIL" -eq 0 ]
