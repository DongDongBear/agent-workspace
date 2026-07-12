#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

if rg -q 'Open in Ghostty|data-open|function openSession\(' "$ROOT/Resources/index.html" \
  || rg -q 'case "/api/open"|func open\(' "$ROOT/Sources/AgentWorkspace.swift"; then
  printf '%s\n' 'FAIL: the removed Ghostty path is still reachable' >&2
  exit 1
fi
if rg -q -- '--dangerously-skip-permissions|--settings|ultracode' "$ROOT/Resources/Bridge"; then
  printf '%s\n' 'FAIL: bundled session launchers must use Claude Code defaults' >&2
  exit 1
fi

APP=$("$ROOT/build.sh" --check | tail -1)
BUILD_ROOT=$(dirname "$APP")
cleanup() { rm -rf "$BUILD_ROOT"; }
trap cleanup EXIT

[ "$(basename "$APP")" = 'Agent Workspace.app' ] || { printf 'FAIL: unexpected app name: %s\n' "$APP" >&2; exit 1; }
plutil -lint "$APP/Contents/Info.plist" >/dev/null
[ "$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")" = AgentWorkspace ] || { printf 'FAIL: wrong executable name\n' >&2; exit 1; }
[ "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" = io.github.dongdongbear.agent-workspace ] || { printf 'FAIL: wrong bundle identifier\n' >&2; exit 1; }
[ -s "$APP/Contents/Resources/AppIcon.icns" ] || { printf 'FAIL: missing bundled app icon\n' >&2; exit 1; }
[ -s "$APP/Contents/Resources/index.html" ] || { printf 'FAIL: missing bundled UI\n' >&2; exit 1; }
cmp "$ROOT/Resources/Bridge/sesslist.sh" "$APP/Contents/Resources/Bridge/sesslist.sh"
cmp "$ROOT/Resources/Bridge/newsess.sh" "$APP/Contents/Resources/Bridge/newsess.sh"
codesign --verify --deep --strict "$APP"
MIN_OS=$(xcrun vtool -show-build "$APP/Contents/MacOS/AgentWorkspace" | awk '/minos/{print $2; exit}')
[ "$MIN_OS" = 13.0 ] || { printf 'FAIL: expected macOS 13.0 deployment target, got %s\n' "$MIN_OS" >&2; exit 1; }

SMOKE=$("$APP/Contents/MacOS/AgentWorkspace" --smoke)
case "$SMOKE" in PASS:*) ;; *) printf 'FAIL: smoke test did not report PASS\n%s\n' "$SMOKE" >&2; exit 1;; esac
UI_TEST=$("$APP/Contents/MacOS/AgentWorkspace" --ui-test -AppleShowScrollBars Always)
case "$UI_TEST" in PASS:*) ;; *) printf 'FAIL: UI test did not report PASS\n%s\n' "$UI_TEST" >&2; exit 1;; esac

printf '%s\n' "$SMOKE"
printf '%s\n' "$UI_TEST"
printf '%s\n' 'PASS: standalone Agent Workspace bundle identity and resources'
