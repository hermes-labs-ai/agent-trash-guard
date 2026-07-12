#!/usr/bin/env bash
set -u
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_DIR/hooks/trash_guard.py"
CLI="$REPO_DIR/bin/claude-trash"
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

bash_event() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

# --- hook: blocks delete commands ---
check "hook blocks rm"              2 "$(hook_exit "$(bash_event 'rm -rf build')")"
check "hook blocks chained rm"      2 "$(hook_exit "$(bash_event 'make && rm -f out.log')")"
check "hook blocks xargs rm"        2 "$(hook_exit "$(bash_event 'ls *.tmp | xargs rm')")"
check "hook blocks sudo rm"         2 "$(hook_exit "$(bash_event 'sudo rm /etc/thing')")"
check "hook blocks find -delete"    2 "$(hook_exit "$(bash_event 'find . -name "*.pyc" -delete')")"
check "hook blocks find -exec rm"   2 "$(hook_exit "$(bash_event 'find . -name x -exec rm {} \;')")"
check "hook blocks git clean -fd"   2 "$(hook_exit "$(bash_event 'git clean -fd')")"
check "hook blocks unlink"          2 "$(hook_exit "$(bash_event 'unlink ./link')")"
check "hook blocks shred"           2 "$(hook_exit "$(bash_event 'shred -u secret.txt')")"
check "hook blocks absolute rm"     2 "$(hook_exit "$(bash_event '/bin/rm -rf build')")"

# --- hook: allows everything else ---
check "hook allows ls"              0 "$(hook_exit "$(bash_event 'ls -la')")"
check "hook allows rm as word"      0 "$(hook_exit "$(bash_event 'echo rm is just a word')")"
check "hook allows rm-suffix cmd"   0 "$(hook_exit "$(bash_event 'npm run charm')")"
check "hook allows git rm"          0 "$(hook_exit "$(bash_event 'git rm --cached file.txt')")"
check "hook allows git clean -n"    0 "$(hook_exit "$(bash_event 'git clean -n')")"
check "hook allows override prefix" 0 "$(hook_exit "$(bash_event 'TRASH_GUARD_ALLOW=1 rm -rf build')")"
check "hook ignores non-Bash tool"  0 "$(hook_exit '{"tool_name":"Read","tool_input":{"file_path":"/x"}}')"
check "hook ignores bad json"       0 "$(hook_exit 'not json at all')"
printf '%s' "$(bash_event 'rm -rf build')" | TRASH_GUARD_ALLOW=1 python3 "$HOOK" 2>/dev/null
check "hook allows env override"    0 "$?"

# --- cli: put / list / restore roundtrip ---
mkdir -p "$WORK/project/sub"
echo "keep me" > "$WORK/project/a.txt"
echo "nested"  > "$WORK/project/sub/b.txt"

python3 "$CLI" put "$WORK/project/a.txt" "$WORK/project/sub/b.txt" > "$WORK/put.out"
check "put exits 0" 0 "$?"
check "put removed a.txt from origin" 1 "$([ -e "$WORK/project/a.txt" ]; echo $?)"
check "put removed b.txt from origin" 1 "$([ -e "$WORK/project/sub/b.txt" ]; echo $?)"

ENTRY_ID="$(python3 "$CLI" list | head -1 | awk '{print $1}')"
check "list shows one entry" 0 "$([ -n "$ENTRY_ID" ]; echo $?)"
python3 "$CLI" list | grep -q "a.txt"
check "list shows original path" 0 "$?"

python3 "$CLI" restore "$ENTRY_ID" > /dev/null
check "restore exits 0" 0 "$?"
check "restore returned a.txt" 0 "$([ -e "$WORK/project/a.txt" ]; echo $?)"
check "restore returned b.txt" 0 "$([ -e "$WORK/project/sub/b.txt" ]; echo $?)"
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
