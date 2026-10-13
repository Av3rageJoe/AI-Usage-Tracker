#!/bin/sh
# Build the widget from source and run every test against it.
#
#   sh tests/run.sh
#
# Offline and hermetic: every test uses a throwaway AI_USAGE_TRACKER_HOME and stub tools
# or local servers. No real login is read, no account list is touched, no API is called.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM

echo "building widget…"
/usr/bin/swiftc -O "$REPO/src/usage-widget.swift" -o "$BUILD/usage-widget" || exit 1
export WIDGET="$BUILD/usage-widget"

failed=""
for t in "$REPO"/tests/*_test.sh "$REPO"/tests/*_test.py; do
  name="$(basename "$t")"
  echo
  echo "== $name"
  case "$t" in
    *.sh) sh "$t" ;;
    *.py) /usr/bin/python3 "$t" ;;
  esac || failed="$failed $name"
done

echo
if [ -n "$failed" ]; then
  echo "FAILED:$failed"
  exit 1
fi
echo "all tests passed"
