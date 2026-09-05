#!/usr/bin/env bash
# Recoverability proof for Agent Trash Guard.
#
# Self-contained, deterministic demonstration that a destructive shell command
# is blocked and that the supported trash workflow loses nothing. It reuses the
# released hook event interface (hooks/trash_guard.py, JSON on stdin) and the
# agent-trash CLI (bin/agent-trash) exactly as shipped.
#
# It proves, in order:
#   1. a representative `rm -rf FILE` shell event is blocked (hook exit 2)
#   2. the recommended replacement, `agent-trash put FILE`, passes the hook
#   3. `agent-trash put` moves the file into a trash entry
#   4. `agent-trash list` exposes the entry and the file's original path
#   5. `agent-trash restore <id>` returns the file to its original path
#   6. the restored file's SHA-256 equals the original, pinned digest
#
# Safety: every path the script creates, moves, or removes lives inside one
# freshly created temporary directory. Cleanup refuses to run unless that
# directory still resolves to a direct child of the system temp directory,
# carries this script's naming prefix, and contains the marker file created
# here. No user file, and no real trash directory, is touched.
#
# Portability: bash 3.2+, python3 (already required by the project), and POSIX
# coreutils only. SHA-256 is computed with Python's hashlib so the proof does
# not depend on sha256sum vs. shasum availability.

set -eu
set -o pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HOOK="$REPO_DIR/hooks/trash_guard.py"
CLI="$REPO_DIR/bin/agent-trash"

DEMO_PREFIX="agent-trash-guard-demo."
MARKER=".agent-trash-guard-demo"
CONTENT='agent-trash-guard recoverability proof
line 2: this content must survive put -> restore unchanged'
# sha256 of CONTENT followed by a single trailing newline (printf '%s\n').
EXPECTED_SHA256="795fb99e949ae9e4bc0898198d9f1041fd8ed9937ab80aaccbd7273164510972"

TOTAL=6
STEP=0

pass() {
  STEP=$((STEP + 1))
  printf 'PASS [%d/%d] %s\n' "$STEP" "$TOTAL" "$1"
}

fail() {
  printf 'FAIL [%d/%d] %s\n' "$((STEP + 1))" "$TOTAL" "$1" >&2
  exit 1
}

info() {
  printf '      %s\n' "$1"
}

# --- isolated workspace -----------------------------------------------------

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_BASE_REAL="$(cd "$TMP_BASE" && pwd -P)"
DEMO_ROOT="$(mktemp -d "$TMP_BASE/${DEMO_PREFIX}XXXXXX")"
readonly TMP_BASE_REAL DEMO_ROOT
: > "$DEMO_ROOT/$MARKER"

# The only permanent delete in this script. It is fenced by the checks below:
# the target must resolve to a direct child of the temp base, carry the demo
# prefix, and contain the marker written above. Anything else is refused.
cleanup() {
  local rc=$?
  local real=""
  if [ -n "${DEMO_ROOT:-}" ] && [ -d "$DEMO_ROOT" ]; then
    real="$(cd "$DEMO_ROOT" 2>/dev/null && pwd -P)" || real=""
    case "$(basename "$real")" in
      "$DEMO_PREFIX"*)
        if [ "$(dirname "$real")" = "$TMP_BASE_REAL" ] \
          && [ "$real" != "/" ] \
          && [ "$real" != "${HOME:-/nonexistent}" ] \
          && [ -f "$real/$MARKER" ]; then
          rm -rf -- "$real"
          info "cleanup: removed workspace $real"
        else
          printf 'cleanup: refused to remove %s (validation failed)\n' "$real" >&2
        fi
        ;;
      *)
        printf 'cleanup: refused to remove %s (unexpected name)\n' "$real" >&2
        ;;
    esac
  fi
  exit "$rc"
}
trap cleanup EXIT

# Point the CLI at a trash directory inside the workspace and drop any
# inherited overrides so the run is independent of the caller's environment.
export AGENT_TRASH_DIR="$DEMO_ROOT/trash"
unset CLAUDE_TRASH_DIR TRASH_GUARD_ALLOW PLUGIN_ROOT CLAUDE_PLUGIN_ROOT

# --- helpers ----------------------------------------------------------------

bash_event() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

# Prints the hook's exit code for an event; stderr guidance goes to file $2.
hook_exit() {
  local rc=0
  printf '%s' "$1" | python3 "$HOOK" 2>"$2" || rc=$?
  echo "$rc"
}

sha256_of() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

# --- fixture ----------------------------------------------------------------

PROJECT="$DEMO_ROOT/project"
TARGET="$PROJECT/important.txt"
mkdir -p "$PROJECT"
printf '%s\n' "$CONTENT" > "$TARGET"
BEFORE="$(sha256_of "$TARGET")"
[ "$BEFORE" = "$EXPECTED_SHA256" ] \
  || fail "fixture digest $BEFORE does not match pinned $EXPECTED_SHA256"

echo "agent-trash-guard recoverability proof"
info "workspace: $DEMO_ROOT"
info "target:    $TARGET"
info "sha256:    $BEFORE"

# --- 1. destructive command is blocked --------------------------------------

RM_COMMAND="rm -rf \"$TARGET\""
BLOCK_ERR="$DEMO_ROOT/hook-block.stderr"
rc="$(hook_exit "$(bash_event "$RM_COMMAND")" "$BLOCK_ERR")"
[ "$rc" = "2" ] || fail "hook returned exit $rc for the rm event, expected 2"
grep -q "trash-guard: blocked a permanent delete" "$BLOCK_ERR" \
  || fail "hook stderr lacks the block notice"
[ -f "$TARGET" ] || fail "target vanished although the command was blocked"
pass "hook blocks \`$RM_COMMAND\` (exit 2); file still present"
info "guidance: $(head -n 1 "$BLOCK_ERR")"

# --- 2. recommended replacement passes the hook -----------------------------

PUT_COMMAND="agent-trash put \"$TARGET\""
rc="$(hook_exit "$(bash_event "$PUT_COMMAND")" "$DEMO_ROOT/hook-allow.stderr")"
[ "$rc" = "0" ] || fail "hook returned exit $rc for the put command, expected 0"
pass "hook allows \`$PUT_COMMAND\` (exit 0)"

# --- 3. put moves the file into a trash entry -------------------------------

PUT_OUT="$DEMO_ROOT/put.out"
python3 "$CLI" put "$TARGET" > "$PUT_OUT" || fail "agent-trash put exited non-zero"
ENTRY_ID="$(sed -n 's/^trashed 1 item(s) -> //p' "$PUT_OUT")"
[ -n "$ENTRY_ID" ] || fail "could not read the entry id from put output"
[ ! -e "$TARGET" ] || fail "target still at its original path after put"
STORED="$AGENT_TRASH_DIR/$ENTRY_ID/important.txt"
[ -f "$STORED" ] || fail "stored copy missing at $STORED"
[ "$(sha256_of "$STORED")" = "$BEFORE" ] || fail "stored copy digest differs"
pass "agent-trash put moved the file out of place and into the trash entry"
info "entry:     $ENTRY_ID"

# --- 4. list exposes the entry ----------------------------------------------

LIST_OUT="$DEMO_ROOT/list.out"
python3 "$CLI" list > "$LIST_OUT" || fail "agent-trash list exited non-zero"
grep -Fq "$ENTRY_ID" "$LIST_OUT" || fail "list output lacks entry $ENTRY_ID"
grep -Fxq "  $TARGET" "$LIST_OUT" || fail "list output lacks the original path"
pass "agent-trash list exposes the entry and its original path"

# --- 5. restore returns the file --------------------------------------------

python3 "$CLI" restore "$ENTRY_ID" > "$DEMO_ROOT/restore.out" \
  || fail "agent-trash restore exited non-zero"
[ -f "$TARGET" ] || fail "target not back at its original path after restore"
python3 "$CLI" list | grep -q "^trash is empty" \
  || fail "entry still listed after a complete restore"
pass "agent-trash restore returned the file to its original path"

# --- 6. content-hash equality -----------------------------------------------

AFTER="$(sha256_of "$TARGET")"
[ "$AFTER" = "$BEFORE" ] || fail "restored digest $AFTER differs from $BEFORE"
[ "$AFTER" = "$EXPECTED_SHA256" ] || fail "restored digest is not the pinned value"
pass "SHA-256 of the restored file equals the original digest"
info "before:    $BEFORE"
info "after:     $AFTER"

echo
echo "RESULT: PASS ($STEP/$TOTAL) blocked, trashed, listed, restored, verified byte-for-byte"
