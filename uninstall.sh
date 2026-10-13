#!/bin/sh
# Stop and remove AI Usage Tracker.
#
#   ./uninstall.sh           remove the app and the login item; keep ~/.ai-usage-tracker
#   ./uninstall.sh --purge   also delete ~/.ai-usage-tracker (account lists and cache)
#
# Never touches a Codex or Claude Code login folder (~/.codex, ~/.claude, or any account
# you added): those belong to those tools. Delete them yourself if you want a login gone.
set -eu
: "${HOME:?HOME must be set}"

APP_HOME="$HOME/.ai-usage-tracker"  # fixed: the app itself always reads this folder
APP="$HOME/Applications/AI Usage Tracker.app"
LABEL="io.github.av3ragejoe.ai-usage-tracker"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$APP"
echo "removed: $APP and its login item"

if [ "${1-}" = "--purge" ]; then
  rm -rf "$APP_HOME"
  echo "removed: $APP_HOME"
else
  echo "kept:    $APP_HOME (run with --purge to delete it)"
fi
