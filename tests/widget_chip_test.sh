#!/bin/sh
# The menu bar chip: one segment per Codex account, then Claude as "CL<7d>". Drives the
# real build() through --chip-from on saved statusline.py / work-mode.py output, so the
# stale, unreadable and colour branches are all exercised without touching the network.
#
#   WIDGET=/path/to/built/binary sh tests/widget_chip_test.sh
set -eu
WIDGET="${WIDGET:?set WIDGET to the compiled usage-widget binary}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
N=0
check() {  # name  work-mode-json-or-MISSING  expected
  N=$((N + 1))
  if [ "$2" = MISSING ]; then rm -f "$TMP/wm.json"; else printf '%s' "$2" > "$TMP/wm.json"; fi
  got="$("$WIDGET" --chip-from "$TMP/sl.json" "$TMP/wm.json")"
  [ "$got" = "$3" ] || { echo "FAIL $1: got [$got] want [$3]"; exit 1; }
  echo "ok   $1"
}

cat > "$TMP/sl.json" <<'EOF'
{"warn_at": 60, "alert_at": 85, "accounts": [
  {"label": "A", "home": "~/.codex", "slots": {"7d": {"pct": 43.2}}, "stale": false},
  {"label": "C", "home": "~/.codex-alt2", "slots": {"7d": {"pct": 29}}, "stale": true}]}
EOF
check "Claude follows the Codex accounts" \
  '{"mode": "NORMAL", "claude": {"7d": 56.4, "5h": 9, "stale": false}}' \
  'A43:green C29*:green CL56:green'
check "a cached Claude figure is starred like Codex" \
  '{"mode": "NORMAL", "claude": {"7d": 56, "5h": 9, "stale": true, "age": 3600}}' \
  'A43:green C29*:green CL56*:green'
check "warn threshold turns it amber" \
  '{"mode": "NORMAL", "claude": {"7d": 70, "5h": 2}}' \
  'A43:green C29*:green CL70:amber'
check "alert threshold turns it red" \
  '{"mode": "NORMAL", "claude": {"7d": 91, "5h": 2}}' \
  'A43:green C29*:green CL91:red'
check "unreadable Claude says so" \
  '{"mode": "UNKNOWN", "claude": null}' \
  'A43:green C29*:green CL?:red'
check "work-mode failing entirely still shows Claude as unknown" MISSING \
  'A43:green C29*:green CL?:red'
# Hostile numbers (a bad header or log line) must render clamped, never crash the widget.
# JSON has no inf/nan, but 1e308 and negatives are valid JSON and trap Int(Double).
cat > "$TMP/sl.json" <<'EOF'
{"warn_at": 1e308, "alert_at": -5, "accounts": [
  {"label": "A", "home": "~/.codex",
   "slots": {"7d": {"pct": 1e308, "resets_at": 1e300}, "5h": {"pct": -1e308}}}]}
EOF
check "huge and negative figures are clamped, not a crash" \
  '{"mode": "NORMAL", "claude": {"7d": 1e308, "5h": -3}}' \
  'A100:red CL100:red'
rm -f "$TMP/sl.json"
check "Codex unreadable keeps the Claude segment" \
  '{"mode": "NORMAL", "claude": {"7d": 12}}' \
  'codex?:red CL12:green'

echo "widget-chip: $N/$N pass"
