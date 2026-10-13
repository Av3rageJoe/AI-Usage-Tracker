#!/bin/sh
# codex-accounts.json has TWO implementations — statusline.py (load_accounts /
# save_accounts) and usage-widget.swift (loadAccounts / saveAccounts). This proves they
# agree in both directions, and that a corrupt file still yields a usable list rather
# than an empty one, which would silently leave every dispatch decision with no accounts.
#
#   WIDGET=/path/to/built/binary sh tests/codex_accounts_test.sh   (tests/run.sh does this)
#
# Runs against a throwaway AI_USAGE_TRACKER_HOME; a real account list is never touched.
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"; export REPO
WIDGET="${WIDGET:?set WIDGET to the compiled usage-widget binary}"
PY=/usr/bin/python3
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
export AI_USAGE_TRACKER_HOME="$TMP/app-home"
mkdir -p "$AI_USAGE_TRACKER_HOME"
CFG="$AI_USAGE_TRACKER_HOME/codex-accounts.json"

py_labels() {
  "$PY" - <<'PYEOF'
import importlib, os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "scripts"))
import statusline
importlib.reload(statusline)  # the list is read at import
print(" ".join(l for l, _ in statusline.CODEX_ACCOUNTS))
PYEOF
}
widget_labels() { "$WIDGET" --accounts | cut -f1 | tr '\n' ' ' | sed 's/ $//'; }
check() { [ "$2" = "$3" ] || { echo "FAIL $1: got [$2] want [$3]"; exit 1; }; echo "ok   $1"; }

# python writes -> swift reads
"$PY" - <<'PYEOF'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "scripts"))
import statusline as sl
sl.save_accounts([("A", os.path.expanduser("~/.codex")),
                  ("B", os.path.expanduser("~/.codex-alt")),
                  ("D", os.path.expanduser("~/.codex-alt9"))])
PYEOF
check "swift reads python's file" "$(widget_labels)" "A B D"

# swift writes -> python reads
"$WIDGET" --add-account E '~/.codex-alt10'
check "python reads swift's file" "$(py_labels)" "A B D E"

# swift removes -> both agree
"$WIDGET" --remove-account B
check "removal, swift side" "$(widget_labels)" "A D E"
check "removal, python side" "$(py_labels)" "A D E"

# a corrupt file must fall back, never yield an empty account list
echo 'not json {{{' > "$CFG"
check "corrupt file falls back" "$(py_labels)" "A"

echo "codex-accounts: 5/5 pass"
