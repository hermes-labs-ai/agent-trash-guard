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

# --- hook: blocks deletes nested in a shell -c / eval argument ---
check "hook blocks bash -c rm"      2 "$(hook_exit "$(bash_event "bash -c \"rm -rf build\"")")"
check "hook blocks sh -c rm"        2 "$(hook_exit "$(bash_event "sh -c 'rm -rf build'")")"
check "hook blocks zsh -c rm"       2 "$(hook_exit "$(bash_event "zsh -c 'rm -rf build'")")"
check "hook blocks dash -c rm"      2 "$(hook_exit "$(bash_event "dash -c 'rm -rf build'")")"
check "hook blocks ksh -c rm"       2 "$(hook_exit "$(bash_event "ksh -c 'rm -rf build'")")"
check "hook blocks eval rm (quoted)" 2 "$(hook_exit "$(bash_event "eval \"rm -rf build\"")")"
check "hook blocks eval rm (bare words)" 2 "$(hook_exit "$(bash_event 'eval rm -rf build')")"
check "hook blocks env-wrapped bash -c rm" 2 "$(hook_exit "$(bash_event "env FOO=1 bash -c 'rm -rf build'")")"
check "hook blocks zsh -c chained rm" 2 "$(hook_exit "$(bash_event 'zsh -c "cd /tmp && rm -rf build"')")"
check "hook blocks bash -lc rm"     2 "$(hook_exit "$(bash_event "bash -lc 'rm -rf build'")")"
check "hook blocks sh -c with &&"   2 "$(hook_exit "$(bash_event "sh -c 'echo hi && rm -rf build'")")"
check "hook blocks nested bash -c sh -c rm" 2 "$(hook_exit "$(bash_event "bash -c \"sh -c 'rm -rf build'\"")")"
check "hook blocks find -delete nested in bash -c" 2 "$(hook_exit "$(bash_event "bash -c \"find . -name '*.pyc' -delete\"")")"
check "hook blocks bare assignment rm"   2 "$(hook_exit "$(bash_event 'FOO=1 rm -rf build')")"
check "hook blocks bare assignment bash -c" 2 "$(hook_exit "$(bash_event "FOO=1 bash -c 'rm -rf build'")")"
check "hook blocks sudo -u rm"      2 "$(hook_exit "$(bash_event 'sudo -u root rm -rf build')")"
check "hook blocks sudo -n rm"      2 "$(hook_exit "$(bash_event 'sudo -n rm -rf build')")"
check "hook blocks rm after if"     2 "$(hook_exit "$(bash_event 'if rm -rf x; then echo bad; fi')")"
check "hook blocks rm after while"  2 "$(hook_exit "$(bash_event 'while rm -rf x; do echo bad; done')")"
check "hook blocks rm after bang"   2 "$(hook_exit "$(bash_event '! rm -rf x')")"

# --- hook: allows everything else ---
check "hook allows ls"              0 "$(hook_exit "$(bash_event 'ls -la')")"
check "hook allows sudo -u root ls" 0 "$(hook_exit "$(bash_event 'sudo -u root ls -la')")"
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

# --- hook: quoted text that is NOT an interpreter/eval argument stays inert ---
check "hook allows python3 -c string mentioning rm" 0 "$(hook_exit "$(bash_event "python3 -c \"print('Bash(rm *)')\"")")"
check "hook allows grep for rm pattern" 0 "$(hook_exit "$(bash_event "grep 'rm -rf' notes.md")")"
check "hook allows echo rm in quotes" 0 "$(hook_exit "$(bash_event 'echo "rm"')")"
check "hook allows bash running a script file" 0 "$(hook_exit "$(bash_event 'bash cleanup.sh')")"

# --- package roots: native schemas and generated cache-isolated runtimes ---
python3 - "$REPO_DIR" <<'PY'
import filecmp
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
# Codex prefers a portable root plugin.json and would ignore these hooks.
assert not (root / ".codex-plugin" / "plugin.json").exists()

# The root is one portable Agent Plugin with one canonical skill.
skill = root / "skills" / "agent-trash-guard" / "SKILL.md"
portable = json.loads((root / "plugin.json").read_text())
assert portable["$schema"] == "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"
assert set(portable) <= {
    "$schema", "name", "version", "description", "author", "homepage",
    "repository", "license", "keywords", "extensions",
}
assert portable["name"] == "agent-trash-guard"
assert portable["version"] == "0.1.3"
skill_text = skill.read_text()
assert skill_text.startswith("---\nname: agent-trash-guard\ndescription: ")
assert "not universal deletion protection" in skill_text
# Strict YAML frontmatter parsers (the skills CLI) reject ": " in a plain scalar.
description = skill_text.split("\n", 3)[2].removeprefix("description: ")
assert ": " not in description and not description.startswith(("'", '"')), description
skills = sorted(
    path.relative_to(root).as_posix() for path in root.rglob("SKILL.md")
    if ".git" not in path.parts
)
assert skills == [
    "integrations/codex/skills/agent-trash-guard/SKILL.md",
    "skills/agent-trash-guard/SKILL.md",
], skills

root_claude = json.loads((root / ".claude-plugin" / "plugin.json").read_text())
assert root_claude["name"] == "agent-trash-guard"
assert root_claude["version"] == portable["version"]
assert root_claude["description"] == portable["description"]
# Reuse the Claude hook file; the root hooks/hooks.json is Gemini's schema.
assert root_claude["hooks"] == "./integrations/claude/hooks/hooks.json"
for key in ("author", "homepage", "repository", "license"):
    assert root_claude[key] == portable[key], key

gemini_manifest = json.loads((root / "gemini-extension.json").read_text())
assert gemini_manifest["name"] == "agent-trash-guard"
assert gemini_manifest["version"] == "0.1.3"
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
assert manifest["version"] == "0.1.3"

# Awesome Copilot's Agent Plugins v1.0.0 intake looks for plugin.json at the
# submitted plugin root (integrations/claude), not inside .claude-plugin/.
root_agent_plugin_path = claude_root / "plugin.json"
assert root_agent_plugin_path.is_file(), "integrations/claude/plugin.json is missing"
agent_plugin = json.loads(root_agent_plugin_path.read_text())
assert agent_plugin["$schema"] == "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"
assert set(agent_plugin) <= {
    "$schema", "name", "version", "description", "author", "homepage",
    "repository", "license", "keywords", "extensions",
}
assert agent_plugin["name"] == manifest["name"] == "claude-trash-guard"
assert agent_plugin["version"] == manifest["version"] == "0.1.3"

marketplace = json.loads((root / ".claude-plugin" / "marketplace.json").read_text())
marketplace_entry = marketplace["plugins"][0]
assert marketplace["name"] == "hermes-labs"
assert marketplace_entry["name"] == manifest["name"]
assert marketplace_entry["version"] == manifest["version"]
assert marketplace_entry["source"] == "./integrations/claude"
root_entry = marketplace["plugins"][1]
assert len(marketplace["plugins"]) == 2
assert root_entry["name"] == root_claude["name"]
assert root_entry["version"] == root_claude["version"]
assert (root / root_entry["source"]).resolve() == root.resolve()
assert filecmp.cmp(skill, root / "integrations" / "codex" / "skills" / "agent-trash-guard" / "SKILL.md", shallow=False)
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

# --- cli: --version reads back the same value across every host bundle ---
ROOT_MANIFEST_VERSION="$(python3 -c "import json; print(json.load(open('$REPO_DIR/plugin.json'))['version'])")"
check "root --version matches root plugin.json" "agent-trash $ROOT_MANIFEST_VERSION" \
  "$(python3 "$CLI" --version)"
check "root --version exits 0" 0 "$?"
check "claude bundle --version matches root" "agent-trash $ROOT_MANIFEST_VERSION" \
  "$(python3 "$REPO_DIR/integrations/claude/bin/agent-trash" --version)"
check "codex bundle --version matches root" "agent-trash $ROOT_MANIFEST_VERSION" \
  "$(python3 "$REPO_DIR/integrations/codex/bin/agent-trash" --version)"
GEMINI_MANIFEST_VERSION="$(python3 -c "import json; print(json.load(open('$REPO_DIR/gemini-extension.json'))['version'])")"
check "gemini-extension.json version matches root plugin.json" "$ROOT_MANIFEST_VERSION" \
  "$GEMINI_MANIFEST_VERSION"

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

# 5b. Whitespace-only and absent bases: main already covers the empty cases below.
RAIL_OUT="$(cd "$RAIL" && HERMES_GATE_BASE="   " python3 .hermes/hermes_gate_runner.py full)"
RAIL_EXIT=$?
check "whitespace HERMES_GATE_BASE errors" "ERROR" \
  "$(printf '%s' "$RAIL_OUT" | rail_field status)"
check "whitespace HERMES_GATE_BASE exits nonzero" 2 "$RAIL_EXIT"

# 5c. An absent base still means the local worktree scope, on a clean and a dirty tree.
RAIL_OUT="$(cd "$RAIL" && env -u HERMES_GATE_BASE python3 .hermes/hermes_gate_runner.py full)"
RAIL_EXIT=$?
check "absent base keeps the worktree scope on a clean tree" "" \
  "$(printf '%s' "$RAIL_OUT" | rail_field range)"
check "absent base is not an error" 0 "$RAIL_EXIT"
printf '%s \n' "worktree trailing whitespace" >> "$RAIL/clean.txt"
RAIL_OUT="$(cd "$RAIL" && env -u HERMES_GATE_BASE python3 .hermes/hermes_gate_runner.py full)"
check "absent base still reviews the dirty worktree" "FAIL" \
  "$(printf '%s' "$RAIL_OUT" | rail_field status)"
rail_git "$RAIL" checkout -q -- clean.txt

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

# 10. The shipped workflows wire the range and keep the job token out of reach of the
#    pull request code they run. The runner's patch is pinned by the behaviour above
#    (sections 2-5c), not by a version string an upstream reinstall could keep.
grep -Fq "fetch-depth: 0" "$REPO_DIR/.github/workflows/hermes-quality.yml"
check "quality workflow fetches the base commit" 0 "$?"
grep -Fq "HERMES_GATE_BASE: \${{ github.event.pull_request.base.sha }}" \
  "$REPO_DIR/.github/workflows/hermes-quality.yml"
check "quality workflow passes the pull request base sha" 0 "$?"
grep -Fq "hermes_gate_runner.py full --all" "$REPO_DIR/.github/workflows/hermes-quality.yml"
check "quality workflow sweeps every byte outside pull requests" 0 "$?"
python3 - "$REPO_DIR/.github/workflows" <<'PY'
import pathlib
import sys

workflow_dir = pathlib.Path(sys.argv[1])
workflows = sorted([*workflow_dir.glob("*.yml"), *workflow_dir.glob("*.yaml")])
assert workflows, "no workflows found"
for workflow in workflows:
    lines = workflow.read_text().splitlines()
    for index, line in enumerate(lines):
        if "uses: actions/checkout" not in line:
            continue
        indent = len(line) - len(line.lstrip())
        # The step body is every following line indented deeper than the step itself.
        body = []
        for follow in lines[index + 1:]:
            if follow.strip() and len(follow) - len(follow.lstrip()) <= indent:
                break
            body.append(follow.strip())
        assert "persist-credentials: false" in body, (
            f"{workflow.name}: checkout step keeps the job token in .git/config"
        )
PY
check "every workflow checkout drops the job token before running pull request code" 0 "$?"
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

# 11. An empty base is a misconfiguration, not a request for the local scope: a rail
#     whose base expression resolves to nothing must say so instead of reviewing a
#     pristine checkout and reporting a pass over zero bytes.
RAIL_OUT="$(cd "$RAIL" && python3 .hermes/hermes_gate_runner.py full --base "")"
RAIL_EXIT=$?
check "empty --base errors" "ERROR" "$(printf '%s' "$RAIL_OUT" | rail_field status)"
check "empty --base exits nonzero" 2 "$RAIL_EXIT"
printf '%s' "$RAIL_OUT" | grep -Fq -- "--base is set but empty"
check "empty --base names the flag" 0 "$?"

RAIL_OUT="$(cd "$RAIL" && python3 .hermes/hermes_gate_runner.py full --base=)"
RAIL_EXIT=$?
check "empty --base= errors" "ERROR" "$(printf '%s' "$RAIL_OUT" | rail_field status)"
check "empty --base= exits nonzero" 2 "$RAIL_EXIT"

RAIL_OUT="$(cd "$RAIL" && HERMES_GATE_BASE="" python3 .hermes/hermes_gate_runner.py full)"
RAIL_EXIT=$?
check "empty HERMES_GATE_BASE errors" "ERROR" "$(printf '%s' "$RAIL_OUT" | rail_field status)"
check "empty HERMES_GATE_BASE exits nonzero" 2 "$RAIL_EXIT"
printf '%s' "$RAIL_OUT" | grep -Fq "HERMES_GATE_BASE is set but empty"
check "empty HERMES_GATE_BASE names the variable" 0 "$?"

RAIL_OUT="$(cd "$RAIL" && HERMES_GATE_BASE="   " python3 .hermes/hermes_gate_runner.py full)"
check "blank HERMES_GATE_BASE errors" "ERROR" "$(printf '%s' "$RAIL_OUT" | rail_field status)"

# An explicit flag still wins over the environment, in both directions.
RAIL_OUT="$(cd "$RAIL" && HERMES_GATE_BASE="" python3 .hermes/hermes_gate_runner.py full \
  --base "$RAIL_BASE")"
check "explicit --base overrides an empty variable" "FAIL" \
  "$(printf '%s' "$RAIL_OUT" | rail_field status)"
RAIL_OUT="$(cd "$RAIL" && HERMES_GATE_BASE="$RAIL_BASE" python3 .hermes/hermes_gate_runner.py \
  full --base "")"
check "explicit empty --base overrides a set variable" "ERROR" \
  "$(printf '%s' "$RAIL_OUT" | rail_field status)"
printf '%s' "$RAIL_OUT" | grep -Fq -- "--base is set but empty"
check "explicit empty --base names the flag" 0 "$?"

# --- gc: reachability is the safety gate, budget is the trigger ---
# Fixtures are local-only: every "remote" is a bare repository on disk, so
# `git ls-remote` is exercised for real without touching the network.
GC_WORK="$WORK/gc"
GC_ORIGINS="$GC_WORK/origins"
GC_REPOS="$GC_WORK/repos"
GC_BUDGET="$GC_WORK/budget"
GC_DENY="$GC_WORK/deny"
mkdir -p "$GC_ORIGINS" "$GC_REPOS" "$GC_BUDGET" "$GC_DENY"

gc_git() {
  local repo="$1"
  shift
  git -C "$repo" -c user.name="Trash Guard Tests" -c user.email="tests@example.invalid" \
    -c commit.gpgsign=false -c protocol.file.allow=always "$@" >/dev/null 2>&1
}

# A repository that is clean, pushed, and whose remote really advertises the
# branch head. This is the only shape the collector is allowed to reclaim.
gc_make_repo() {
  local name="$1"
  git init -q --bare "$GC_ORIGINS/$name.git" >/dev/null 2>&1
  git init -q -b main "$GC_REPOS/$name" >/dev/null 2>&1
  printf '%s\n' "$name" > "$GC_REPOS/$name/file.txt"
  gc_git "$GC_REPOS/$name" add file.txt
  gc_git "$GC_REPOS/$name" commit -m "initial"
  gc_git "$GC_REPOS/$name" remote add origin "$GC_ORIGINS/$name.git"
  gc_git "$GC_REPOS/$name" push -u origin main
}

gc_make_repo clean
gc_make_repo dirty
printf '%s\n' "not committed" > "$GC_REPOS/dirty/untracked.txt"
gc_make_repo unpushed
printf '%s\n' "second" > "$GC_REPOS/unpushed/file.txt"
gc_git "$GC_REPOS/unpushed" commit -am "unpushed work"
gc_make_repo stashed
printf '%s\n' "work in progress, parked in a stash" > "$GC_REPOS/stashed/file.txt"
gc_git "$GC_REPOS/stashed" stash push -m "trash-guard-gc-fixture"
# An orphaned worktree: .git points at a gitdir that no longer exists, so every
# git call fails. A failing git call must never read as "clean".
mkdir -p "$GC_REPOS/broken"
printf 'gitdir: %s\n' "$GC_WORK/gone/.git/worktrees/broken" > "$GC_REPOS/broken/.git"
printf '%s\n' "orphaned" > "$GC_REPOS/broken/file.txt"
# Clean and pushed like `clean`, but explicitly denylisted.
gc_make_repo guarded

# Non-git accumulation with controlled sizes and ages for the budget ladder.
python3 - "$GC_BUDGET" "$GC_DENY" <<'PY'
import os
import sys
import time

budget_root, deny_root = sys.argv[1], sys.argv[2]
now = time.time()
for name, age_days in (("old-30d", 30), ("old-20d", 20), ("old-10d", 10)):
    path = os.path.join(budget_root, name)
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, "blob.bin"), "wb") as handle:
        handle.write(b"\0" * (1024 * 1024))
    stamp = now - age_days * 86400
    os.utime(os.path.join(path, "blob.bin"), (stamp, stamp))
    os.utime(path, (stamp, stamp))

# Hard invariants: a file literally named profiles.db, and a directory that
# merely contains corpus.db. Both are old, unreachable and over budget.
stamp = now - 400 * 86400
target = os.path.join(deny_root, "profiles.db")
with open(target, "wb") as handle:
    handle.write(b"\0" * 4096)
os.utime(target, (stamp, stamp))
holder = os.path.join(deny_root, "some-archive")
os.makedirs(holder, exist_ok=True)
with open(os.path.join(holder, "corpus.db"), "wb") as handle:
    handle.write(b"\0" * 4096)
os.utime(os.path.join(holder, "corpus.db"), (stamp, stamp))
os.utime(holder, (stamp, stamp))
PY

gc_run() {
  python3 "$CLI" gc --json "$@" > "$WORK/gc.json" 2>"$WORK/gc.err"
}

gc_query() {
  python3 - "$WORK/gc.json" "$@" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1]))
mode = sys.argv[2]
if mode == "count":
    print(sum(1 for e in report["entries"] if e["decision"] == sys.argv[3]))
elif mode == "total":
    print(report["totals"][sys.argv[3]])
else:
    needle = "/" + sys.argv[3]
    for entry in report["entries"]:
        if entry["path"].endswith(needle):
            if mode == "evidence":
                print(len(entry["evidence"]))
            else:
                print(entry[mode])
            break
    else:
        print("missing")
PY
}

# 1. Reachability gate, with the age floor and the budget both wide open, so
#    the only thing separating these repositories is what git says about them.
gc_run --roots "$GC_REPOS" --older-than 0 --budget 0 --protect "$GC_REPOS/guarded"
check "gc exits 0" 0 "$?"
check "clean pushed repo is collectable" "collect" "$(gc_query decision clean)"
check "clean pushed repo is unreachable" "unreachable" "$(gc_query verdict clean)"
check "clean pushed repo is decided by the budget rule" 5 "$(gc_query rule clean)"
check "dirty repo is kept" "keep" "$(gc_query decision dirty)"
check "dirty repo is reachable" "reachable" "$(gc_query verdict dirty)"
check "dirty repo is decided by rule 3" 3 "$(gc_query rule dirty)"
check "unpushed repo is kept" "keep" "$(gc_query decision unpushed)"
check "unpushed repo is reachable" "reachable" "$(gc_query verdict unpushed)"
check "stashed repo is kept" "keep" "$(gc_query decision stashed)"
check "stashed repo is reachable" "reachable" "$(gc_query verdict stashed)"
# The dangerous false negative: git failing must produce UNKNOWN, not dirty=0.
check "repo whose git errors is kept" "keep" "$(gc_query decision broken)"
check "repo whose git errors is unknown, not clean" "unknown" \
  "$(gc_query verdict broken)"
check "unknown git state is decided by rule 2" 2 "$(gc_query rule broken)"
check "unknown git state records its evidence" 0 \
  "$(nonempty_exit "$(gc_query evidence broken)")"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); e=[x for x in r["entries"] if x["path"].endswith("/broken")][0]; sys.exit(0 if any(i["result"]=="unknown" for i in e["evidence"]) else 1)' "$WORK/gc.json"
check "unknown evidence names the failing git call" 0 "$?"
# Rule 1 outranks rule 5: denylisted, yet clean, old and over budget.
check "denylisted repo is kept" "keep" "$(gc_query decision guarded)"
check "denylisted repo is decided by rule 1, not rule 5" 1 \
  "$(gc_query rule guarded)"

# 2. --dry-run is the default: a reporting run mutates nothing.
check "dry run left the collectable repo in place" 0 \
  "$(exists_exit "$GC_REPOS/clean")"
check "dry run left the dirty repo in place" 0 "$(exists_exit "$GC_REPOS/dirty")"
check "dry run reports itself as a dry run" "True" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dry_run"])' "$WORK/gc.json")"
check "dry run reclaimed nothing" 0 "$(gc_query total reclaimed_bytes)"

# 3. The built-in denylist needs no configuration at all.
gc_run --roots "$GC_DENY" --older-than 0 --budget 0
check "profiles.db is never collected" "keep" "$(gc_query decision profiles.db)"
check "profiles.db is decided by rule 1" 1 "$(gc_query rule profiles.db)"
check "a subtree holding corpus.db is never collected" "keep" \
  "$(gc_query decision some-archive)"
check "corpus.db holder is decided by rule 1" 1 "$(gc_query rule some-archive)"

# 4. Budget is the trigger, and it stops as soon as the footprint fits.
gc_run --roots "$GC_BUDGET" --older-than 1 --budget 2500K
check "budget collects only what it must" 1 "$(gc_query count collect)"
check "budget collects the oldest first" "collect" "$(gc_query decision old-30d)"
check "budget leaves the next-oldest alone" "keep" "$(gc_query decision old-20d)"
check "candidate spared by a satisfied budget cites rule 5" 5 \
  "$(gc_query rule old-20d)"
gc_run --roots "$GC_BUDGET" --older-than 1 --budget 0
check "a zero budget collects every eligible candidate" 3 \
  "$(gc_query count collect)"
# Without a budget nothing triggers collection at all.
gc_run --roots "$GC_BUDGET" --older-than 1
check "no budget means no collection" 0 "$(gc_query count collect)"
check "no budget falls through to rule 6" 6 "$(gc_query rule old-30d)"

# 5. The age floor is a floor: budget pressure does not lower it.
gc_run --roots "$GC_BUDGET" --older-than 15 --budget 0
check "age floor keeps the young candidate" "keep" "$(gc_query decision old-10d)"
check "age floor is rule 4" 4 "$(gc_query rule old-10d)"
check "age floor still allows the old candidates" 2 "$(gc_query count collect)"

# 6. Flags that must refuse rather than guess.
python3 "$CLI" gc --roots "$GC_BUDGET" --dry-run --collect >/dev/null 2>&1
check "--dry-run with --collect is refused" 1 "$?"
python3 "$CLI" gc --roots "$HOME" >/dev/null 2>&1
check "the home directory is refused as a root" 1 "$?"
python3 "$CLI" gc --roots / >/dev/null 2>&1
check "the filesystem root is refused as a root" 1 "$?"
python3 "$CLI" gc --roots "$GC_BUDGET" --budget nonsense >/dev/null 2>&1
check "an unparseable budget is refused" 2 "$?"

# 7. --offline refuses to trust a remote it cannot reach, so the checkout it
#    cannot confirm stays UNKNOWN and is kept.
gc_git "$GC_REPOS/clean" remote set-url origin "https://example.invalid/clean.git"
gc_run --roots "$GC_REPOS" --older-than 0 --budget 0 --offline
check "offline mode cannot confirm a network remote" "unknown" \
  "$(gc_query verdict clean)"
check "an unconfirmable remote is kept" "keep" "$(gc_query decision clean)"
gc_git "$GC_REPOS/clean" remote set-url origin "$GC_ORIGINS/clean.git"

# 8. --collect actually reclaims, and only what the ladder chose.
gc_run --roots "$GC_REPOS" --older-than 0 --budget 0 --collect \
  --protect "$GC_REPOS/guarded" --receipt "$WORK/gc-receipt.jsonl"
check "collect exits 0" 0 "$?"
check "collect removed the clean pushed repo" 1 "$(exists_exit "$GC_REPOS/clean")"
check "collect spared the dirty repo" 0 "$(exists_exit "$GC_REPOS/dirty")"
check "collect spared the unpushed repo" 0 "$(exists_exit "$GC_REPOS/unpushed")"
check "collect spared the stashed repo" 0 "$(exists_exit "$GC_REPOS/stashed")"
check "collect spared the repo whose git errors" 0 \
  "$(exists_exit "$GC_REPOS/broken")"
check "collect spared the denylisted repo" 0 "$(exists_exit "$GC_REPOS/guarded")"
check "collect wrote an audit receipt" 0 "$(exists_exit "$WORK/gc-receipt.jsonl")"
python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).read().splitlines()[0]); sys.exit(0 if all(e["rule"] and e["reason"] and e["path"] for e in r["entries"]) else 1)' "$WORK/gc-receipt.jsonl"
check "every receipt entry names a rule, a reason and a path" 0 "$?"

echo
echo "$PASS passed, $FAIL failed"
rm -rf "$WORK"
[ "$FAIL" -eq 0 ]
