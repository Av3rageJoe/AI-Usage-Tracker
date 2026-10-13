#!/bin/sh
# Claude account storage and authentication launchers live entirely in
# usage-widget.swift. Every assertion below invokes the binary under WIDGET so the test
# cannot accidentally certify an installed, stale app after compiling a review build.
# Runs against a throwaway AI_USAGE_TRACKER_HOME; a real account list is never touched.
set -eu

WIDGET="${WIDGET:?set WIDGET to the compiled usage-widget binary}"
PY=/usr/bin/python3
TMP="$(mktemp -d)"
export AI_USAGE_TRACKER_HOME="$TMP/app-home"
mkdir -p "$AI_USAGE_TRACKER_HOME"
CFG="$AI_USAGE_TRACKER_HOME/claude-accounts.json"
# A "~/..." path is needed to prove tilde expansion; it is removed on exit.
TILDE_DIR="$HOME/.aiut-claude-account-test-$$"
restore() { rm -rf "$TMP" "$TILDE_DIR"; }
trap restore EXIT HUP INT TERM

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; exit 1; }

write_seed() {
  "$PY" - "$CFG" <<'PYEOF'
import json, sys
with open(sys.argv[1], "w") as f:
    json.dump({"accounts": [{"label": "Default", "config_dir": "~/.claude"}]}, f)
PYEOF
}

normalised_widget_records() {
  "$WIDGET" --claude-accounts | "$PY" -c '
import os, sys
for raw in sys.stdin:
    label, config_dir = raw.rstrip("\n").split("\t", 1)
    print(label + "\t" + os.path.realpath(os.path.expanduser(config_dir)))
'
}

# The real machine lookup must find Claude at an executable absolute path (when installed).
CLAUDE_PATH="$($WIDGET --resolve-tools | awk -F '\t' '$1 == "claude" { print $2 }')"
[ -n "$CLAUDE_PATH" ] || fail "tool resolution" "claude line missing"
if [ "$CLAUDE_PATH" = MISSING ]; then
  echo "skip absolute tool resolution (Claude Code is not installed)"
else
  [ "${CLAUDE_PATH#/}" != "$CLAUDE_PATH" ] || fail "tool resolution" "path is not absolute"
  [ -x "$CLAUDE_PATH" ] || fail "tool resolution" "$CLAUDE_PATH is not executable"
fi
pass "absolute tool resolution"

TOOLS="$TMP/tools"
mkdir "$TOOLS"
cat > "$TOOLS/codex" <<'STUBEOF'
#!/bin/sh
if [ "${1-}" = auth ]; then config_dir=$CLAUDE_CONFIG_DIR; else config_dir=$CODEX_HOME; fi
{
  printf 'config_dir=%s\n' "$config_dir"
  printf 'argc=%s\n' "$#"
  n=1
  for arg in "$@"; do printf 'arg%s=%s\n' "$n" "$arg"; n=$((n + 1)); done
} > "$UW_STUB_RECORD"
exit "${UW_STUB_EXIT:-0}"
STUBEOF
cp "$TOOLS/codex" "$TOOLS/claude"
chmod 700 "$TOOLS/codex" "$TOOLS/claude"

# Execute the shipped Codex launcher with both path and label metacharacters. Comparing
# /tmp before/after avoids deleting an unrelated pre-existing PWNED_* diagnostic file.
BAD_DIR="x'\"; touch /tmp/PWNED_\$\$; echo '"
BAD_LABEL='label`touch /tmp/PWNED_LABEL_$$`'
PWNED_BEFORE="$(find /tmp -maxdepth 1 -name 'PWNED_*' -print | sort)"
LAUNCH_INFO="$(UW_TOOL_DIR="$TOOLS" "$WIDGET" --make-auth-launcher \
  codex login "$BAD_LABEL" "$BAD_DIR")"
LAUNCHER="$(printf '%s\n' "$LAUNCH_INFO" | cut -f1)"
SENTINEL="$(printf '%s\n' "$LAUNCH_INFO" | cut -f2)"
[ -f "$LAUNCHER" ] || fail "safe launcher" "launcher was not written"
[ "$(stat -f '%Lp' "$LAUNCHER")" = 700 ] || fail "safe launcher" "mode is not 0700"
grep -F "$TOOLS/codex" "$LAUNCHER" >/dev/null \
  || fail "safe launcher" "absolute stub path missing"
if grep -Eq '(^|[[:space:]])codex([[:space:]]|$)' "$LAUNCHER"; then
  fail "safe launcher" "contains bare codex executable"
fi
UW_STUB_RECORD="$TMP/codex-record" UW_STUB_EXIT=0 sh "$LAUNCHER" >/dev/null
[ ! -e "$LAUNCHER" ] || fail "safe launcher" "launcher did not remove itself"
[ "$(cat "$SENTINEL")" = 0 ] || fail "safe launcher" "success sentinel is not 0"
RECORDED_DIR="$(sed -n 's/^config_dir=//p' "$TMP/codex-record")"
[ "$RECORDED_DIR" = "$BAD_DIR" ] \
  || fail "safe launcher" "config directory changed across the shell boundary"
[ "$(sed -n 's/^argc=//p' "$TMP/codex-record")" = 1 ] \
  || fail "safe launcher" "codex argv was split"
[ "$(sed -n 's/^arg1=//p' "$TMP/codex-record")" = login ] \
  || fail "safe launcher" "codex login argv changed"
PWNED_AFTER="$(find /tmp -maxdepth 1 -name 'PWNED_*' -print | sort)"
[ "$PWNED_BEFORE" = "$PWNED_AFTER" ] || fail "safe launcher" "shell payload executed"
rm -f "$SENTINEL"
pass "launcher quoting and success sentinel"

# The completion signal must be written on the failure path too.
LAUNCH_INFO="$(UW_TOOL_DIR="$TOOLS" "$WIDGET" --make-auth-launcher \
  claude login 'Failure label' "$TMP/failure-dir")"
LAUNCHER="$(printf '%s\n' "$LAUNCH_INFO" | cut -f1)"
SENTINEL="$(printf '%s\n' "$LAUNCH_INFO" | cut -f2)"
UW_STUB_RECORD="$TMP/claude-record" UW_STUB_EXIT=7 sh "$LAUNCHER" >/dev/null
[ ! -e "$LAUNCHER" ] || fail "failure sentinel" "launcher did not remove itself"
[ "$(cat "$SENTINEL")" = 7 ] || fail "failure sentinel" "sentinel is not 7"
[ "$(sed -n 's/^config_dir=//p' "$TMP/claude-record")" = "$TMP/failure-dir" ] \
  || fail "failure sentinel" "CLAUDE_CONFIG_DIR changed"
[ "$(sed -n 's/^argc=//p' "$TMP/claude-record")" = 2 ] \
  || fail "failure sentinel" "claude argv was split"
rm -f "$SENTINEL"
pass "failure sentinel"

# Round-trip the complete records, normalising paths on both sides rather than comparing
# labels alone. The first added path also proves ~/ expansion.
write_seed
mkdir -p "$TILDE_DIR" "$TMP/second"
TILDE_STORED="~/$(basename "$TILDE_DIR")"
"$WIDGET" --add-claude-account Alt "$TILDE_STORED"
"$WIDGET" --add-claude-account Temp "$TMP/second"
ACTUAL="$(normalised_widget_records)"
EXPECTED="$(printf 'Default\t%s\nAlt\t%s\nTemp\t%s' \
  "$("$PY" -c 'import os; print(os.path.realpath(os.path.expanduser("~/.claude")))')" \
  "$(cd "$TILDE_DIR" && pwd -P)" "$(cd "$TMP/second" && pwd -P)")"
[ "$ACTUAL" = "$EXPECTED" ] || fail "whole-record round trip" "records differ"
"$WIDGET" --remove-claude-account Temp
case "$(normalised_widget_records)" in
  *"Temp"*) fail "whole-record round trip" "removed record remains" ;;
esac
pass "whole-record round trip and tilde expansion"

if "$WIDGET" --add-claude-account Alt "$TMP/other" 2>/dev/null; then
  fail "duplicate label" "duplicate was accepted"
fi
pass "duplicate label rejected"

if "$WIDGET" --add-claude-account Other "$TILDE_STORED" 2>/dev/null; then
  fail "duplicate directory" "duplicate was accepted"
fi
pass "duplicate directory rejected"

printf 'not json {{{\n' > "$CFG"
[ "$($WIDGET --claude-accounts)" = "Default	~/.claude" ] \
  || fail "malformed fallback" "did not return the default"
pass "malformed JSON falls back"

printf '{"accounts":[]}\n' > "$CFG"
[ "$($WIDGET --claude-accounts)" = "Default	~/.claude" ] \
  || fail "empty fallback" "did not return the default"
pass "empty array falls back"

write_seed
if "$WIDGET" --remove-claude-account Default 2>/dev/null; then
  fail "default protection" "literal default was removed"
fi
[ "$($WIDGET --claude-accounts)" = "Default	~/.claude" ] \
  || fail "default protection" "literal default changed"
pass "literal default removal refused"

ln -s "$HOME/.claude" "$TMP/default-alias"
"$PY" - "$CFG" "$TMP/default-alias" <<'PYEOF'
import json, sys
with open(sys.argv[1], "w") as f:
    json.dump({"accounts": [{"label": "Alias", "config_dir": sys.argv[2]}]}, f)
PYEOF
if "$WIDGET" --remove-claude-account Alias 2>/dev/null; then
  fail "canonical default protection" "symlinked default was removed"
fi
pass "symlinked default removal refused"

write_seed
MENU_LINE="$($WIDGET --check-menus | awk -F '\t' \
  '$2 ~ /^Remove… \(default account/ && $4 == "removeClaudeAccount:" { print; exit }')"
[ -n "$MENU_LINE" ] || fail "menu metadata" "default Remove line missing"
[ "$(printf '%s\n' "$MENU_LINE" | cut -f3)" = false ] \
  || fail "menu metadata" "default Remove is enabled"
pass "default Remove menu item disabled"

echo "claude-accounts: 11/11 pass"
