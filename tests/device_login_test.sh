#!/bin/sh
# The Codex "Add account" flow hands a device-code link to whoever owns the account and
# must write codex-accounts.json ONLY after the sign-in finished. Drives the real
# DeviceLogin through `--device-login` against a stub codex; never runs a real login.
#
#   WIDGET=/path/to/built/binary sh tests/device_login_test.sh   (tests/run.sh does this)
#
# Runs against a throwaway AI_USAGE_TRACKER_HOME; a real account list is never touched.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"; export REPO
WIDGET="${WIDGET:?set WIDGET to the compiled usage-widget binary}"
PY=/usr/bin/python3
TMP="$(mktemp -d)"
export AI_USAGE_TRACKER_HOME="$TMP/app-home"
mkdir -p "$AI_USAGE_TRACKER_HOME"
# A "~/..." CODEX_HOME is needed to prove tilde expansion; it is removed on exit.
TILDE_HOME="$HOME/.aiut-device-test-$$"
restore() { rm -rf "$TMP" "$TILDE_HOME"; }
trap restore EXIT HUP INT TERM

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; exit 1; }
listed() { "$WIDGET" --accounts | cut -f1 | grep -qx "$1"; }
py_listed() {
  "$PY" - "$1" <<'PYEOF'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "scripts"))
import statusline
sys.exit(0 if sys.argv[1] in [l for l, _ in statusline.CODEX_ACCOUNTS] else 1)
PYEOF
}

# The stub is `#!/usr/bin/env fakenode`, like npm's `#!/usr/bin/env node` codex: it only
# runs if the widget puts the tool's own directory on PATH. Its behaviour comes from a
# file in CODEX_HOME because the widget hands the child a clean environment.
TOOLS="$TMP/tools"
mkdir "$TOOLS"
printf '#!/bin/sh\nexec /bin/sh "$@"\n' > "$TOOLS/fakenode"
cat > "$TOOLS/codex" <<'STUBEOF'
#!/usr/bin/env fakenode
{
  printf 'codex_home=%s\n' "$CODEX_HOME"
  printf 'argc=%s\n' "$#"
  n=1
  for arg in "$@"; do printf 'arg%s=%s\n' "$n" "$arg"; n=$((n + 1)); done
  printf 'marker=%s\n' "${UW_LEAK_MARKER-unset}"
} > "$CODEX_HOME/stub-record"
printf 'Follow these steps to sign in with ChatGPT using device code authorization:\n\n'
printf '1. Open this link in your browser and sign in to your account\n'
printf '   \033[94mhttps://auth.openai.com/codex/device\033[0m\n\n'
printf '2. Enter this one-time code \033[90m(expires in 15 minutes)\033[0m\n'
printf '   \033[94mWXYZ-98765\033[0m\n\n'
printf 'Device codes are a common phishing target. Never share this code.\n\n'
case "$(cat "$CODEX_HOME/stub-mode")" in
  wait)
    i=0
    while [ ! -e "$CODEX_HOME/release" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
    printf '{}' > "$CODEX_HOME/auth.json"; echo 'Successfully logged in.'; exit 0 ;;
  success) printf '{}' > "$CODEX_HOME/auth.json"; echo 'Successfully logged in.'; exit 0 ;;
  noauth) echo 'Successfully logged in.'; exit 0 ;;
  expired) echo 'Error logging in with device code: device code expired' >&2; exit 1 ;;
  *) echo 'Error logging in with device code: boom' >&2; exit 1 ;;
esac
STUBEOF
chmod 700 "$TOOLS/fakenode" "$TOOLS/codex"
export UW_LEAK_MARKER=leaked   # must NOT reach the child

run_login() {  # label home mode
  mkdir -p "$(eval echo "$2")"
  echo "$3" > "$(eval echo "$2")/stub-mode"
  UW_TOOL_DIR="$TOOLS" "$WIDGET" --device-login "$1" "$2" || true
}

# 1. The account is absent while the sign-in is pending, present once it finishes.
mkdir -p "$TILDE_HOME"
echo wait > "$TILDE_HOME/stub-mode"
UW_TOOL_DIR="$TOOLS" "$WIDGET" --device-login P "~/$(basename "$TILDE_HOME")" \
  > "$TMP/pending.out" 2>&1 &
PID=$!
i=0
until grep -q '^LINK' "$TMP/pending.out" 2>/dev/null || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
grep -q '^LINK' "$TMP/pending.out" || fail "pending" "no LINK line: $(cat "$TMP/pending.out")"
if listed P; then fail "pending" "account listed before the sign-in finished"; fi
if py_listed P; then fail "pending" "statusline.py sees the account before it finished"; fi
touch "$TILDE_HOME/release"
wait "$PID" || fail "pending" "device login exited non-zero: $(cat "$TMP/pending.out")"
grep -qx 'ADDED	P' "$TMP/pending.out" || fail "pending" "no ADDED line"
listed P || fail "pending" "account missing after the sign-in finished"
py_listed P || fail "pending" "statusline.py does not see the finished account"
pass "not listed while pending, listed once finished (swift + python)"

# 2. The link and code are parsed out of coloured output, exactly.
LINE="$(grep '^LINK' "$TMP/pending.out")"
[ "$LINE" = "$(printf 'LINK\thttps://auth.openai.com/codex/device\tWXYZ-98765\t15')" ] \
  || fail "parse" "got [$LINE]"
pass "link, code and lifetime parsed from ANSI output"

# 3. Exact argv, expanded CODEX_HOME, file credential store, clean environment.
REC="$TILDE_HOME/stub-record"
[ "$(sed -n 's/^codex_home=//p' "$REC")" = "$TILDE_HOME" ] || fail "argv" "CODEX_HOME not expanded"
[ "$(sed -n 's/^argc=//p' "$REC")" = 4 ] || fail "argv" "argc is not 4"
[ "$(sed -n 's/^arg1=//p' "$REC") $(sed -n 's/^arg2=//p' "$REC")" = "login --device-auth" ] \
  || fail "argv" "not login --device-auth"
[ "$(sed -n 's/^arg3=//p' "$REC")" = "-c" ] || fail "argv" "no -c"
[ "$(sed -n 's/^arg4=//p' "$REC")" = 'cli_auth_credentials_store="file"' ] \
  || fail "argv" "credential store not pinned to file"
[ "$(sed -n 's/^marker=//p' "$REC")" = unset ] || fail "env" "parent environment leaked"
pass "argv, CODEX_HOME, file store, clean env, env-node shebang runs"

# 4. Failure, expiry and success-without-auth.json all leave the list alone.
OUT="$(run_login F "$TMP/fail" boom)"
case "$OUT" in *NOT-ADDED*"boom"*) ;; *) fail "failure" "got [$OUT]" ;; esac
if listed F; then fail "failure" "failed sign-in was listed"; fi
pass "failed sign-in not added"

OUT="$(run_login E "$TMP/expired" expired)"
case "$OUT" in *NOT-ADDED*"code expired"*) ;; *) fail "expiry" "got [$OUT]" ;; esac
if listed E; then fail "expiry" "expired sign-in was listed"; fi
pass "expired code reported and not added"

OUT="$(run_login N "$TMP/noauth" noauth)"
case "$OUT" in *NOT-ADDED*"no auth.json"*) ;; *) fail "noauth" "got [$OUT]" ;; esac
if listed N; then fail "noauth" "account without auth.json was listed"; fi
pass "exit 0 without auth.json not added"

# 5. A CODEX_HOME the widget creates is owner-only: it will hold a login and session logs.
OUT="$(UW_TOOL_DIR="$TOOLS" "$WIDGET" --device-login G "$TMP/fresh/nested" || true)"
[ -d "$TMP/fresh/nested" ] || fail "private folder" "CODEX_HOME was not created"
[ "$(stat -f '%Lp' "$TMP/fresh/nested")" = 700 ] \
  || fail "private folder" "mode is $(stat -f '%Lp' "$TMP/fresh/nested"), not 700"
if listed G; then fail "private folder" "failed sign-in was listed"; fi
pass "a new CODEX_HOME is created 0700"

# 6. A duplicate is refused before Codex is even started.
mkdir -p "$TMP/dup"; echo success > "$TMP/dup/stub-mode"
OUT="$(UW_TOOL_DIR="$TOOLS" "$WIDGET" --device-login P "$TMP/dup" || true)"
[ "$OUT" = "$(printf 'NOT-ADDED\talready listed')" ] || fail "duplicate" "got [$OUT]"
[ ! -e "$TMP/dup/stub-record" ] || fail "duplicate" "codex ran for a duplicate"
pass "duplicate label refused without running codex"

echo "device-login: 8/8 pass"
