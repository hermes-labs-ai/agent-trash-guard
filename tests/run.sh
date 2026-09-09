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

# --- package roots: native schemas and generated cache-isolated runtimes ---
python3 - "$REPO_DIR" <<'PY'
import filecmp
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
assert not (root / ".claude-plugin" / "plugin.json").exists()
assert not (root / ".codex-plugin" / "plugin.json").exists()

gemini_manifest = json.loads((root / "gemini-extension.json").read_text())
assert gemini_manifest["name"] == "agent-trash-guard"
assert gemini_manifest["version"] == "0.1.2"
gemini_hooks = json.loads((root / "hooks" / "hooks.json").read_text())
gemini_entry = gemini_hooks["hooks"]["BeforeTool"][0]
assert gemini_entry["matcher"] == "run_shell_command"
assert gemini_entry["hooks"][0]["command"] == (
    'python3 "${extensionPath}${/}hooks${/}trash_guard.py"'
)
assert gemini_entry["hooks"][0]["timeout"] == 8000

claude_root = root / "integrations" / "claude"
manifest = json.loads((claude_root / ".claude-plugin" / "plugin.json").read_text())
assert manifest["name"] == "claude-trash-guard"
assert manifest["version"] == "0.1.2"
marketplace = json.loads((root / ".claude-plugin" / "marketplace.json").read_text())
marketplace_entry = marketplace["plugins"][0]
assert marketplace["name"] == "hermes-labs"
assert marketplace_entry["name"] == manifest["name"]
assert marketplace_entry["version"] == manifest["version"]
assert marketplace_entry["source"] == "./integrations/claude"
hooks = json.loads((claude_root / "hooks" / "hooks.json").read_text())
entry = hooks["hooks"]["PreToolUse"][0]
assert entry["matcher"] == "Bash"
command = entry["hooks"][0]
assert command["command"] == "python3"
assert command["args"] == ["${CLAUDE_PLUGIN_ROOT}/hooks/trash_guard.py"]

codex_root = root / "integrations" / "codex"
codex = json.loads((codex_root / ".codex-plugin" / "plugin.json").read_text())
assert codex["name"] == "agent-trash-guard"
assert codex["hooks"] == "./hooks/codex.json"
codex_hooks = json.loads((codex_root / "hooks" / "codex.json").read_text())
codex_entry = codex_hooks["hooks"]["PreToolUse"][0]
assert codex_entry["matcher"] == "Bash"
assert codex_entry["hooks"][0]["command"] == "python3 ${PLUGIN_ROOT}/hooks/trash_guard.py"

codex_market = json.loads((root / ".agents" / "plugins" / "marketplace.json").read_text())
assert codex_market["interface"]["displayName"] == "Hermes Labs"
assert codex_market["plugins"][0]["name"] == "agent-trash-guard"
assert codex_market["plugins"][0]["source"] == {
    "source": "local",
    "path": "./integrations/codex",
}
assert codex_market["plugins"][0]["policy"] == {
    "installation": "AVAILABLE",
    "authentication": "ON_INSTALL",
}
assert codex_market["plugins"][0]["category"] == "Productivity"

for adapter_root in (claude_root, codex_root):
    for relative in (
        "hooks/trash_guard.py",
        "bin/agent-trash",
        "bin/claude-trash",
        "lib/agent_trash.py",
    ):
        assert filecmp.cmp(root / relative, adapter_root / relative, shallow=False)
PY
check "package roots and generated runtimes are valid" 0 "$?"

python3 "$REPO_DIR/tools/build_platform_bundles.py" --check >/dev/null
check "generated runtime parity check passes" 0 "$?"

PLUGIN_ERR="$({
  printf '%s' "$(bash_event 'rm -rf build')" |
    CLAUDE_PLUGIN_ROOT="$REPO_DIR" python3 "$HOOK" 2>&1 >/dev/null
} || true)"
printf '%s' "$PLUGIN_ERR" | grep -Fq "\"$REPO_DIR/bin/agent-trash\" put <path...>"
check "plugin guidance uses bundled CLI" 0 "$?"

PACKAGE_WITH_SPACES="$WORK/Claude package space"
cp -R "$REPO_DIR/integrations/claude" "$PACKAGE_WITH_SPACES"
PACKAGE_REALPATH="$(python3 - "$PACKAGE_WITH_SPACES" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
)"
SPACE_ERR="$({
  printf '%s' "$(bash_event 'rm -rf build')" |
    env -u CLAUDE_PLUGIN_ROOT -u PLUGIN_ROOT -u AGENT_TRASH_GUARD_ROOT \
      python3 "$PACKAGE_WITH_SPACES/hooks/trash_guard.py" 2>&1 >/dev/null
} || true)"
printf '%s' "$SPACE_ERR" | grep -Fq "\"$PACKAGE_REALPATH/bin/agent-trash\" put <path...>"
check "self-contained package guidance survives spaces" 0 "$?"

python3 "$LEGACY_CLI" --help 2>&1 | grep -q "agent-trash"
check "legacy claude-trash command remains compatible" 0 "$?"

# --- Gemini installer: isolated registration and removal ---
mkdir -p "$WORK/gemini"
python3 - "$WORK/gemini/settings.json" "$REPO_DIR" <<'PY'
import json
import pathlib
import sys
owned_command = f"python3 {sys.argv[2]}/hooks/trash_guard.py"
pathlib.Path(sys.argv[1]).write_text(json.dumps({"hooks": {"BeforeTool": [{
    "matcher": "run_shell_command",
    "hooks": [
        {
            "name": "agent-trash-guard",
            "type": "command",
            "command": "python3 /foreign/trash_guard.py",
            "timeout": 1234,
        },
        {
            "name": "agent-trash-guard",
            "type": "prompt",
            "command": owned_command,
        },
    ],
}]}}))
PY
GEMINI_SETTINGS="$WORK/gemini/settings.json" BIN_DIR="$WORK/bin" \
  "$REPO_DIR/integrations/gemini/install.sh" >/dev/null
python3 - "$WORK/gemini/settings.json" "$REPO_DIR" <<'PY'
import json
import pathlib
import sys
settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
groups = settings["hooks"]["BeforeTool"]
assert len(groups) == 2
assert groups[0]["hooks"][0]["command"] == "python3 /foreign/trash_guard.py"
assert groups[0]["hooks"][1]["type"] == "prompt"
entry = groups[1]
assert entry["matcher"] == "run_shell_command"
assert entry["hooks"][0]["command"] == f"python3 {sys.argv[2]}/hooks/trash_guard.py"
assert entry["hooks"][0]["timeout"] == 8000
PY
check "Gemini installer registers native hook" 0 "$?"
GEMINI_SETTINGS="$WORK/gemini/settings.json" BIN_DIR="$WORK/bin" \
  "$REPO_DIR/integrations/gemini/uninstall.sh" >/dev/null
python3 - "$WORK/gemini/settings.json" <<'PY'
import json
import pathlib
import sys
settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
groups = settings["hooks"]["BeforeTool"]
assert len(groups) == 1
assert groups[0]["hooks"][0]["command"] == "python3 /foreign/trash_guard.py"
assert groups[0]["hooks"][1]["type"] == "prompt"
PY
check "Gemini uninstaller removes only its exact native hook" 0 "$?"
check "Gemini uninstaller removes owned CLI link" 1 "$(exists_exit "$WORK/bin/agent-trash")"

# Gemini install refuses a file or foreign symlink and uninstall preserves it.
mkdir -p "$WORK/gemini-collision-bin"
printf '%s\n' "keep me" > "$WORK/gemini-collision-bin/agent-trash"
GEMINI_SETTINGS="$WORK/gemini-collision/settings.json" \
  BIN_DIR="$WORK/gemini-collision-bin" \
  "$REPO_DIR/integrations/gemini/install.sh" >/dev/null 2>&1
check "Gemini installer refuses non-owned CLI file" 1 "$?"
check "Gemini installer preserves non-owned CLI file" "keep me" \
  "$(cat "$WORK/gemini-collision-bin/agent-trash")"
rm "$WORK/gemini-collision-bin/agent-trash"
ln -s /bin/echo "$WORK/gemini-collision-bin/agent-trash"
GEMINI_SETTINGS="$WORK/gemini-collision/settings.json" \
  BIN_DIR="$WORK/gemini-collision-bin" \
  "$REPO_DIR/integrations/gemini/uninstall.sh" >/dev/null
check "Gemini uninstaller preserves foreign CLI link" 0 \
  "$(exists_exit "$WORK/gemini-collision-bin/agent-trash")"

# Gemini quotes paths before persisting a shell command.
SPECIAL_ROOT="$WORK/repo space;literal"
ln -s "$REPO_DIR" "$SPECIAL_ROOT"
AGENT_TRASH_GUARD_ROOT="$SPECIAL_ROOT" \
  GEMINI_SETTINGS="$WORK/gemini-special/settings.json" \
  BIN_DIR="$WORK/gemini-special-bin" \
  "$REPO_DIR/integrations/gemini/install.sh" >/dev/null
python3 - "$WORK/gemini-special/settings.json" "$SPECIAL_ROOT" <<'PY'
import json
import pathlib
import shlex
import sys
settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
command = settings["hooks"]["BeforeTool"][0]["hooks"][0]["command"]
expected = "python3 " + shlex.quote(str(pathlib.Path(sys.argv[2]) / "hooks" / "trash_guard.py"))
assert command == expected
PY
check "Gemini installer shell-quotes special repo path" 0 "$?"
SPECIAL_COMMAND="$(python3 - "$WORK/gemini-special/settings.json" <<'PY'
import json
import pathlib
import sys
settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(settings["hooks"]["BeforeTool"][0]["hooks"][0]["command"])
PY
)"
printf '%s' "$(gemini_event 'rm -rf build')" | sh -c "$SPECIAL_COMMAND" 2>/dev/null
check "quoted Gemini hook command executes and blocks" 2 "$?"
AGENT_TRASH_GUARD_ROOT="$SPECIAL_ROOT" \
  GEMINI_SETTINGS="$WORK/gemini-special/settings.json" \
  BIN_DIR="$WORK/gemini-special-bin" \
  "$REPO_DIR/integrations/gemini/uninstall.sh" >/dev/null

# Manual Claude install has the same collision and ownership guarantees.
mkdir -p "$WORK/claude-collision-bin"
printf '%s\n' "keep me too" > "$WORK/claude-collision-bin/agent-trash"
CLAUDE_SETTINGS="$WORK/claude-collision/settings.json" \
  BIN_DIR="$WORK/claude-collision-bin" "$REPO_DIR/install.sh" >/dev/null 2>&1
check "Claude installer refuses non-owned CLI file" 1 "$?"
check "Claude installer leaves no partial legacy link" 1 \
  "$(exists_exit "$WORK/claude-collision-bin/claude-trash")"
check "Claude installer preserves non-owned CLI file" "keep me too" \
  "$(cat "$WORK/claude-collision-bin/agent-trash")"

CLAUDE_SETTINGS="$WORK/claude-owned/settings.json" BIN_DIR="$WORK/claude-owned-bin" \
  "$REPO_DIR/install.sh" >/dev/null
check "Claude installer creates owned neutral link" 0 \
  "$(exists_exit "$WORK/claude-owned-bin/agent-trash")"
check "Claude installer creates owned legacy link" 0 \
  "$(exists_exit "$WORK/claude-owned-bin/claude-trash")"
"$WORK/claude-owned-bin/agent-trash" --help 2>&1 | grep -q "agent-trash"
check "neutral CLI runs through installed symlink" 0 "$?"
"$WORK/claude-owned-bin/claude-trash" --help 2>&1 | grep -q "agent-trash"
check "legacy CLI runs through installed symlink" 0 "$?"
python3 - "$WORK/claude-owned/settings.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
settings = json.loads(path.read_text())
settings["hooks"]["PreToolUse"].append({
    "matcher": "Bash",
    "hooks": [{"type": "command", "command": "python3 /foreign/trash_guard.py"}],
})
path.write_text(json.dumps(settings))
PY
CLAUDE_SETTINGS="$WORK/claude-owned/settings.json" BIN_DIR="$WORK/claude-owned-bin" \
  "$REPO_DIR/uninstall.sh" >/dev/null
check "Claude uninstaller removes owned neutral link" 1 \
  "$(exists_exit "$WORK/claude-owned-bin/agent-trash")"
check "Claude uninstaller removes owned legacy link" 1 \
  "$(exists_exit "$WORK/claude-owned-bin/claude-trash")"
python3 - "$WORK/claude-owned/settings.json" <<'PY'
import json
import pathlib
import sys

settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert settings["hooks"]["PreToolUse"] == [{
    "matcher": "Bash",
    "hooks": [{"type": "command", "command": "python3 /foreign/trash_guard.py"}],
}]
PY
check "Claude uninstaller preserves foreign legacy hook" 0 "$?"

python3 - "$WORK/claude-old-root/settings.json" "$REPO_DIR" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
old_command = f"python3 {sys.argv[2]}/hooks/trash_guard.py"
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({"hooks": {"PreToolUse": [{
    "matcher": "Bash",
    "hooks": [
        {"type": "command", "command": old_command},
        {"type": "command", "command": "python3 /foreign/trash_guard.py"},
    ],
}]}}))
PY
CLAUDE_SETTINGS="$WORK/claude-old-root/settings.json" BIN_DIR="$WORK/claude-old-root-bin" \
  "$REPO_DIR/uninstall.sh" >/dev/null
python3 - "$WORK/claude-old-root/settings.json" <<'PY'
import json
import pathlib
import sys

settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert settings["hooks"]["PreToolUse"] == [{
    "matcher": "Bash",
    "hooks": [{"type": "command", "command": "python3 /foreign/trash_guard.py"}],
}]
PY
check "Claude uninstaller migrates old root hook safely" 0 "$?"

mkdir -p "$WORK/claude-foreign-bin"
ln -s /bin/echo "$WORK/claude-foreign-bin/agent-trash"
ln -s /bin/echo "$WORK/claude-foreign-bin/claude-trash"
CLAUDE_SETTINGS="$WORK/claude-foreign/settings.json" BIN_DIR="$WORK/claude-foreign-bin" \
  "$REPO_DIR/uninstall.sh" >/dev/null
check "Claude uninstaller preserves foreign neutral link" 0 \
  "$(exists_exit "$WORK/claude-foreign-bin/agent-trash")"
check "Claude uninstaller preserves foreign legacy link" 0 \
  "$(exists_exit "$WORK/claude-foreign-bin/claude-trash")"

# --- cli: invalid source sets are rejected atomically ---
mkdir -p "$WORK/atomic/project/dir"
printf '%s\n' "atomic" > "$WORK/atomic/project/file.txt"
printf '%s\n' "nested" > "$WORK/atomic/project/dir/child.txt"
AGENT_TRASH_DIR="$WORK/atomic/trash-duplicate" \
  python3 "$CLI" put "$WORK/atomic/project/file.txt" "$WORK/atomic/project/file.txt" \
  >/dev/null 2>&1
check "put rejects duplicate source paths" 1 "$?"
check "duplicate refusal leaves source untouched" 0 \
  "$(exists_exit "$WORK/atomic/project/file.txt")"
check "duplicate refusal creates no trash entry" 1 \
  "$(exists_exit "$WORK/atomic/trash-duplicate")"
AGENT_TRASH_DIR="$WORK/atomic/trash-overlap" \
  python3 "$CLI" put "$WORK/atomic/project/dir" "$WORK/atomic/project/dir/child.txt" \
  >/dev/null 2>&1
check "put rejects ancestor-descendant source paths" 1 "$?"
check "overlap refusal leaves ancestor untouched" 0 \
  "$(exists_exit "$WORK/atomic/project/dir")"
check "overlap refusal leaves descendant untouched" 0 \
  "$(exists_exit "$WORK/atomic/project/dir/child.txt")"
check "overlap refusal creates no trash entry" 1 \
  "$(exists_exit "$WORK/atomic/trash-overlap")"

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

# --- quality rail: review range, declared stages, preserved local scope ---
# A hosted checkout has no worktree changes, so a worktree-only gate reports a green
# rail over zero bytes. These fixtures pin the repaired behaviour: the range the rail
# reviews, every declared full stage, and the unchanged local worktree scope.
RAIL_RUNNER="$REPO_DIR/.hermes/hermes_gate_runner.py"
RAIL_PROFILE="$REPO_DIR/.hermes/gate.toml"

rail_git() {
  local repo="$1"
  shift
  git -C "$repo" -c user.name="Trash Guard Tests" -c user.email="tests@example.invalid" \
    -c commit.gpgsign=false "$@"
}

# Builds a repository whose *committed* bytes carry a whitespace error the worktree
# cannot see, which is exactly the shape a pull request checkout has.
rail_fixture() {
  local repo="$1" profile="${2:-$RAIL_PROFILE}"
  mkdir -p "$repo/.hermes"
  cp "$RAIL_RUNNER" "$repo/.hermes/hermes_gate_runner.py"
  cp "$profile" "$repo/.hermes/gate.toml"
  git -c init.defaultBranch=main init -q "$repo"
  printf '%s\n' "clean" > "$repo/clean.txt"
  rail_git "$repo" add -A
  rail_git "$repo" commit -qm "base"
  # Kept outside the fixture so the checkout stays pristine, like a CI checkout.
  rail_git "$repo" rev-parse HEAD > "$repo.base"
  printf '%s \n' "committed trailing whitespace" > "$repo/offending.txt"
  rail_git "$repo" add -A
  rail_git "$repo" commit -qm "introduce whitespace error"
}

rail_field() {
  python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}

rail_stages() {
  python3 -c 'import json,sys; print(",".join(c["name"] + ":" + c["status"] for c in json.load(sys.stdin)["checks"]))'
}

RAIL="$WORK/rail"
rail_fixture "$RAIL"
RAIL_BASE="$(cat "$RAIL.base")"

# 1. Hosted-checkout shape: a clean worktree must never report a passing stage.
RAIL_OUT="$(cd "$RAIL" && python3 .hermes/hermes_gate_runner.py full)"
check "clean checkout full reports no applicable stage" "NOT_APPLICABLE" \
  "$(printf '%s' "$RAIL_OUT" | rail_field status)"
check "clean checkout full records no passing stage" "diff-check:NOT_APPLICABLE" \
  "$(printf '%s' "$RAIL_OUT" | rail_stages)"

# 2. The review range is the pull request base compared with HEAD.
RAIL_OUT="$(cd "$RAIL" && python3 .hermes/hermes_gate_runner.py full --base "$RAIL_BASE")"
RAIL_EXIT=$?
check "base range full fails on committed whitespace" "FAIL" \
  "$(printf '%s' "$RAIL_OUT" | rail_field status)"
check "base range full exits nonzero" 1 "$RAIL_EXIT"
check "base range is base...HEAD" "$RAIL_BASE...HEAD" \
  "$(printf '%s' "$RAIL_OUT" | rail_field range)"
printf '%s' "$RAIL_OUT" | grep -Fq "offending.txt:1: trailing whitespace."
check "base range names the offending committed line" 0 "$?"

# 3. CI passes the base through the environment; the flag and the variable agree.
RAIL_OUT="$(cd "$RAIL" && HERMES_GATE_BASE="$RAIL_BASE" python3 .hermes/hermes_gate_runner.py full)"
check "HERMES_GATE_BASE selects the same range" "FAIL" \
  "$(printf '%s' "$RAIL_OUT" | rail_field status)"

# 4. A range that introduces nothing is honest about it instead of claiming a pass.
RAIL_OUT="$(cd "$RAIL" && python3 .hermes/hermes_gate_runner.py full --base HEAD)"
check "empty range reports no applicable stage" "NOT_APPLICABLE" \
  "$(printf '%s' "$RAIL_OUT" | rail_field status)"

# 5. A base the checkout does not carry is an error, never a silent empty scan.
RAIL_OUT="$(cd "$RAIL" && python3 .hermes/hermes_gate_runner.py full \
  --base 0000000000000000000000000000000000000000)"
RAIL_EXIT=$?
check "unresolvable base errors" "ERROR" "$(printf '%s' "$RAIL_OUT" | rail_field status)"
check "unresolvable base exits nonzero" 1 "$RAIL_EXIT"

# 6. Manual dispatch reviews every committed byte.
RAIL_OUT="$(cd "$RAIL" && python3 .hermes/hermes_gate_runner.py full --all)"
check "--all fails on committed whitespace" "FAIL" \
  "$(printf '%s' "$RAIL_OUT" | rail_field status)"

# 7. Local scope is unchanged: worktree, index and untracked bytes still drive the gate.
printf '%s \n' "worktree trailing whitespace" >> "$RAIL/clean.txt"
RAIL_OUT="$(cd "$RAIL" && python3 .hermes/hermes_gate_runner.py full)"
check "local worktree change still fails full" "FAIL" \
  "$(printf '%s' "$RAIL_OUT" | rail_field status)"
check "local run keeps the worktree scope" "" "$(printf '%s' "$RAIL_OUT" | rail_field range)"
RAIL_OUT="$(cd "$RAIL" && python3 .hermes/hermes_gate_runner.py fast)"
check "local worktree change still fails fast" "FAIL" \
  "$(printf '%s' "$RAIL_OUT" | rail_field status)"
rail_git "$RAIL" checkout -q -- clean.txt
printf '%s \n' "untracked trailing whitespace" > "$RAIL/untracked.txt"
RAIL_OUT="$(cd "$RAIL" && python3 .hermes/hermes_gate_runner.py fast)"
check "local untracked file still fails fast" "FAIL" \
  "$(printf '%s' "$RAIL_OUT" | rail_field status)"
rm -f "$RAIL/untracked.txt"

# 8. full owes the caller every declared stage; fast keeps its first-failure budget exit.
cat > "$WORK/multi-stage.toml" <<'TOML'
version = 1

[gate]
fast_budget_seconds = 8.0
exclusions = [".git/**", ".hermes/hermes_gate_runner.py"]

[[fast]]
name = "first"
argv = ["python3", "-c", "raise SystemExit(1)", "{files}"]
timeout_seconds = 4.0
globs = ["**/*"]

[[fast]]
name = "second"
argv = ["python3", "-c", "raise SystemExit(0)", "{files}"]
timeout_seconds = 4.0
globs = ["**/*"]

[[full]]
name = "first"
argv = ["python3", "-c", "raise SystemExit(1)", "{files}"]
timeout_seconds = 10.0
globs = ["**/*"]

[[full]]
name = "second"
argv = ["python3", "-c", "raise SystemExit(0)", "{files}"]
timeout_seconds = 10.0
globs = ["**/*"]

[[full]]
name = "fileless"
argv = ["python3", "-c", "raise SystemExit(0)"]
timeout_seconds = 10.0
globs = ["**/*"]
TOML
RAIL_MULTI="$WORK/rail-multi"
rail_fixture "$RAIL_MULTI" "$WORK/multi-stage.toml"
RAIL_MULTI_BASE="$(cat "$RAIL_MULTI.base")"
RAIL_OUT="$(cd "$RAIL_MULTI" && python3 .hermes/hermes_gate_runner.py full \
  --base "$RAIL_MULTI_BASE")"
check "full runs every declared stage past a failure" \
  "first:FAIL,second:PASS,fileless:PASS" "$(printf '%s' "$RAIL_OUT" | rail_stages)"
check "full reports the failing stage" "FAIL" "$(printf '%s' "$RAIL_OUT" | rail_field status)"
printf '%s' "$RAIL_OUT" | grep -Fq "failed stages: first"
check "full names the failing stage" 0 "$?"
printf '%s \n' "worktree trailing whitespace" >> "$RAIL_MULTI/clean.txt"
RAIL_OUT="$(cd "$RAIL_MULTI" && python3 .hermes/hermes_gate_runner.py fast)"
check "fast still stops at the first failing stage" "first:FAIL" \
  "$(printf '%s' "$RAIL_OUT" | rail_stages)"
# A stage that reads no files still runs on a clean tree.
rail_git "$RAIL_MULTI" checkout -q -- clean.txt
RAIL_OUT="$(cd "$RAIL_MULTI" && python3 .hermes/hermes_gate_runner.py full)"
check "file-less stage still runs on a clean tree" \
  "first:NOT_APPLICABLE,second:NOT_APPLICABLE,fileless:PASS" \
  "$(printf '%s' "$RAIL_OUT" | rail_stages)"

# 9. A stage that cannot be launched at all, or that is declared unusably, is that
#    stage's own result: the later declared stages still run.
RAIL_LAUNCH="$WORK/rail-launch"
mkdir -p "$RAIL_LAUNCH"
printf '%s\n' "#!/usr/bin/env bash" "exit 0" > "$WORK/not-executable.sh"
chmod 000 "$WORK/not-executable.sh"
cat > "$WORK/launch-stage.toml" <<TOML
version = 1

[gate]
fast_budget_seconds = 8.0
exclusions = [".git/**", ".hermes/hermes_gate_runner.py"]

[[fast]]
name = "diff-check"
argv = ["python3", ".hermes/hermes_gate_runner.py", "diff-check", "{files}"]
timeout_seconds = 4.0
globs = ["**/*"]

[[full]]
name = "missing-command"
argv = ["$WORK/definitely-not-installed-command", "{files}"]
timeout_seconds = 10.0
globs = ["**/*"]

[[full]]
name = "not-executable"
argv = ["$WORK/not-executable.sh", "{files}"]
timeout_seconds = 10.0
globs = ["**/*"]

[[full]]
name = "empty-argv"
argv = []
timeout_seconds = 10.0
globs = ["**/*"]

[[full]]
name = "non-string-argv"
argv = ["python3", 7]
timeout_seconds = 10.0
globs = ["**/*"]

[[full]]
name = "sentinel"
argv = ["python3", "-c", "raise SystemExit(0)", "{files}"]
timeout_seconds = 10.0
globs = ["**/*"]
TOML
rail_fixture "$RAIL_LAUNCH" "$WORK/launch-stage.toml"
RAIL_LAUNCH_BASE="$(cat "$RAIL_LAUNCH.base")"
RAIL_OUT="$(cd "$RAIL_LAUNCH" && python3 .hermes/hermes_gate_runner.py full \
  --base "$RAIL_LAUNCH_BASE")"
RAIL_EXIT=$?
check "stage launch errors do not abort the remaining stages" \
  "missing-command:FAIL,not-executable:FAIL,empty-argv:ERROR,non-string-argv:ERROR,sentinel:PASS" \
  "$(printf '%s' "$RAIL_OUT" | rail_stages)"
check "unusable declarations surface as an error" "ERROR" \
  "$(printf '%s' "$RAIL_OUT" | rail_field status)"
check "unusable declarations exit nonzero" 1 "$RAIL_EXIT"
printf '%s' "$RAIL_OUT" | grep -Fq "unusable stage declarations: empty-argv, non-string-argv"
check "error names every unusable stage" 0 "$?"
printf '%s' "$RAIL_OUT" | grep -Fq "failed stages: missing-command, not-executable"
check "error still names the stages that failed to launch" 0 "$?"
chmod 700 "$WORK/not-executable.sh"

# 10. The shipped workflow wires the range, and the runner keeps its repository patch,
#    so an upstream byte-for-byte reinstall cannot quietly restore the vacuous rail.
grep -Fq "fetch-depth: 0" "$REPO_DIR/.github/workflows/hermes-quality.yml"
check "quality workflow fetches the base commit" 0 "$?"
grep -Fq "HERMES_GATE_BASE: \${{ github.event.pull_request.base.sha }}" \
  "$REPO_DIR/.github/workflows/hermes-quality.yml"
check "quality workflow passes the pull request base sha" 0 "$?"
grep -Fq "hermes_gate_runner.py full --all" "$REPO_DIR/.github/workflows/hermes-quality.yml"
check "quality workflow sweeps every byte outside pull requests" 0 "$?"
grep -Fq 'RUNNER_PATCH = "hermes-labs/review-range-1"' "$RAIL_RUNNER"
check "repository runner carries its review-range patch" 0 "$?"
python3 - "$RAIL_PROFILE" "$RAIL_RUNNER" <<'PY'
import pathlib
import sys
import tomllib

profile = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
# The patched runner is this repository's own source, so gate and review scope must
# see it; the generated upstream profile excluded it as a byte-for-byte copy.
assert ".hermes/hermes_gate_runner.py" not in profile["gate"]["exclusions"]
assert profile["review"]["timeout_seconds"] >= 600.0
PY
check "profile keeps the patched runner in review scope" 0 "$?"

echo
echo "$PASS passed, $FAIL failed"
rm -rf "$WORK"
[ "$FAIL" -eq 0 ]
