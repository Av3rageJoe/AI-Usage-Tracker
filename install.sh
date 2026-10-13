#!/bin/sh
# Build and install "AI Usage Tracker.app", and start it at login. Idempotent: run it
# again after pulling changes. Needs only the Xcode Command Line Tools (swiftc, python3).
#
#   ./install.sh
#
# What it writes, and nothing else:
#   ~/.ai-usage-tracker/                     scripts, account lists, cache (owner-only)
#   ~/Applications/AI Usage Tracker.app      the widget (Spotlight: "AI Usage Tracker")
#   ~/Library/LaunchAgents/io.github.av3ragejoe.ai-usage-tracker.plist   start at login
#
# It never reads, copies or moves a credential. Codex and Claude Code keep their own
# logins; the widget only reads usage with them, in place.
set -eu
: "${HOME:?HOME must be set}"

REPO="$(cd "$(dirname "$0")" && pwd)"
APP_HOME="$HOME/.ai-usage-tracker"  # fixed: the app itself always reads this folder
APP="$HOME/Applications/AI Usage Tracker.app"
EXE="$APP/Contents/MacOS/AIUsageTracker"
LABEL="io.github.av3ragejoe.ai-usage-tracker"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ "$(uname -s)" = Darwin ] || { echo "AI Usage Tracker runs on macOS only." >&2; exit 1; }
for tool in /usr/bin/swiftc /usr/bin/python3; do
  "$tool" --version >/dev/null 2>&1 || {
    echo "Missing $tool. Install the Command Line Tools first:  xcode-select --install" >&2
    exit 1
  }
done

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# 1. Scripts and config. Existing account lists are kept; only missing ones are seeded.
mkdir -p "$APP_HOME/cache"
chmod 700 "$APP_HOME"
install -m 644 "$REPO/scripts/statusline.py" "$REPO/scripts/work-mode.py" "$APP_HOME/"
install -m 755 "$REPO/scripts/ai-usage" "$APP_HOME/"
[ -f "$APP_HOME/codex-accounts.json" ] || cat > "$APP_HOME/codex-accounts.json" <<'EOF'
{
  "accounts": [
    {
      "home": "~/.codex",
      "label": "A"
    }
  ]
}
EOF
[ -f "$APP_HOME/claude-accounts.json" ] || cat > "$APP_HOME/claude-accounts.json" <<'EOF'
{
  "accounts": [
    {
      "config_dir": "~/.claude",
      "label": "Default"
    }
  ]
}
EOF

# 2. The app.
/usr/bin/swiftc -O "$REPO/src/usage-widget.swift" -o "$BUILD/AIUsageTracker"

# The icon is drawn by the binary itself, from the same palette as the card.
"$BUILD/AIUsageTracker" --icon "$BUILD/icon.png" >/dev/null
mkdir -p "$BUILD/icon.iconset"
for s in 16 32 64 128 256 512 1024; do
  sips -z $s $s "$BUILD/icon.png" --out "$BUILD/icon.iconset/icon_${s}x${s}.png" >/dev/null 2>&1
done
# iconutil wants the @2x names too; reuse the next size up.
for s in 16 32 128 256 512; do
  cp "$BUILD/icon.iconset/icon_$((s * 2))x$((s * 2)).png" "$BUILD/icon.iconset/icon_${s}x${s}@2x.png"
done
rm -f "$BUILD/icon.iconset/icon_64x64.png" "$BUILD/icon.iconset/icon_1024x1024.png"
iconutil -c icns "$BUILD/icon.iconset" -o "$BUILD/icon.icns"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BUILD/AIUsageTracker" "$EXE"
mv "$BUILD/icon.icns" "$APP/Contents/Resources/icon.icns"
cat > "$APP/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AI Usage Tracker</string>
  <key>CFBundleDisplayName</key><string>AI Usage Tracker</string>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleExecutable</key><string>AIUsageTracker</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Menu bar only: no Dock icon, no app switcher entry — but still Spotlight-launchable. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLISTEOF
# Ad-hoc signature: built on this Mac from source, so Gatekeeper has nothing to quarantine.
/usr/bin/codesign --force --deep --sign - "$APP" 2>/dev/null || true

# Register with Launch Services and Spotlight so the name is searchable straight away.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP" 2>/dev/null || true
mdimport "$APP" 2>/dev/null || true

# 3. Start at login. No KeepAlive: "Quit" from the menu must actually quit, not respawn.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$EXE</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLISTEOF

DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout is asynchronous: bootstrapping before the old job has fully torn down fails
# with "Input/output error 5". Wait for it to disappear, then retry a couple of times.
i=0
while launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
  sleep 0.25; i=$((i + 1))
done
i=0
until launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -ge 5 ] && { echo "launchctl bootstrap failed after $i attempts" >&2; exit 1; }
  sleep 1
done

echo "installed: $APP"
echo "  config:    $APP_HOME"
echo "  Spotlight: \"AI Usage Tracker\"   ·   starts at login"
echo "  check:     \"$EXE\" --dump"
echo "  terminal:  $APP_HOME/ai-usage"
echo "  remove:    $REPO/uninstall.sh"
