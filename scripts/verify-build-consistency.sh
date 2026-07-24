#!/usr/bin/env bash
# verify-build-consistency.sh
# Checks build config consistency across project.yml, Info.plist, entitlements.
# Usage: ./scripts/verify-build-consistency.sh [--app-path /path/to/DevPulse.app]
#   Without --app-path, runs source-level checks only.
#   With --app-path, also validates the built app bundle.

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/DevPulseNative"
APP_PATH=""
PASS=0; FAIL=0; SKIP=0

pass() { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1" >&2; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP: %s\n' "$1"; }

PLIST="$PROJECT_DIR/App/Info.plist"
WPLIST="$PROJECT_DIR/Widget/Info.plist"
YML="$PROJECT_DIR/project.yml"
APENT="$PROJECT_DIR/App/DevPulse.entitlements"
WDENT="$PROJECT_DIR/Widget/DevPulseWidgetExtension.entitlements"


# ── project.yml source-of-truth ──
echo "=== project.yml source-of-truth ==="
YML_APP_BID=$(grep 'PRODUCT_BUNDLE_IDENTIFIER: local.devpulse.app$' "$YML" | head -1 | sed 's/.*: //' | tr -d ' ')
YML_WIDGET_BID=$(grep 'PRODUCT_BUNDLE_IDENTIFIER: local.devpulse.app.widget$' "$YML" | head -1 | sed 's/.*: //' | tr -d ' ')
YML_VERSION=$(grep 'MARKETING_VERSION:' "$YML" | head -1 | sed 's/.*: *//;s/^"//;s/"$//')
YML_BUILD=$(grep 'CURRENT_PROJECT_VERSION:' "$YML" | head -1 | sed 's/.*: *//;s/^"//;s/"$//')

# Check bundle IDs in project.yml
[ -n "$YML_APP_BID" ] && pass "App bundle ID in project.yml: $YML_APP_BID" || fail "App bundle ID not found in project.yml"
[ -n "$YML_WIDGET_BID" ] && pass "Widget bundle ID in project.yml: $YML_WIDGET_BID" || fail "Widget bundle ID not found in project.yml"
[ -n "$YML_VERSION" ] && pass "Marketing version in project.yml: $YML_VERSION" || fail "Marketing version not found"
[ -n "$YML_BUILD" ] && pass "Build version in project.yml: $YML_BUILD" || fail "Build version not found"

# Deployment target
DEPLOY_TARGET=$(grep 'macOS:' "$YML" | head -1 | sed 's/.*macOS: *"\(.*\)"/\1/' | tr -d '"')
[ "$DEPLOY_TARGET" = "14.0" ] && pass "Deployment target: macOS $DEPLOY_TARGET" || fail "Deployment target: $DEPLOY_TARGET (expected 14.0)"

# App Group in entitlements config
YML_APP_GROUP=$(grep -A2 'application-groups:' "$YML" | grep 'group.local.devpulse')
[ -n "$YML_APP_GROUP" ] && pass "App Group 'group.local.devpulse' in project.yml" || fail "App Group missing from project.yml"

# WIDGET_TEST compilation condition
grep -q "WIDGET_TEST" "$YML" && pass "WIDGET_TEST compilation condition in project.yml" || fail "WIDGET_TEST missing from project.yml"

# Swift 6
grep -q "SWIFT_VERSION:.*6" "$YML" && pass "Swift 6 configured in project.yml" || fail "Swift 6 not configured in project.yml"

# ── Info.plist (build settings variables are correct) ──
echo ""
echo "=== Info.plist build-setting references ==="
[ -f "$PLIST" ] && pass "App Info.plist exists" || fail "App Info.plist missing"
[ -f "$WPLIST" ] && pass "Widget Info.plist exists" || fail "Widget Info.plist missing"

# Check that Info.plist files use build variable references (not hardcoded values)
[ -f "$PLIST" ] && grep -q 'PRODUCT_BUNDLE_IDENTIFIER' "$PLIST" 2>/dev/null && pass "App Info.plist uses build-variable bundle ID" || fail "App Info.plist may have hardcoded bundle ID"
[ -f "$WPLIST" ] && grep -q 'PRODUCT_BUNDLE_IDENTIFIER' "$WPLIST" 2>/dev/null && pass "Widget Info.plist uses build-variable bundle ID" || fail "Widget Info.plist may have hardcoded bundle ID"

LMSV=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST" 2>/dev/null || true)
[ "$LMSV" = "14.0" ] && pass "App Info.plist: min OS $LMSV" || fail "App Info.plist: min OS is '$LMSV', expected 14.0"

# Widget extension point
WEP=$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPointIdentifier" "$WPLIST" 2>/dev/null || true)
[ "$WEP" = "com.apple.widgetkit-extension" ] && pass "Widget Info.plist: extension point $WEP" || fail "Widget Info.plist: extension point '$WEP'"

# ── Entitlements ──
echo ""
echo "=== Entitlements ==="
[ -f "$APENT" ] && pass "App entitlements exist" || fail "App entitlements missing"
[ -f "$WDENT" ] && pass "Widget entitlements exist" || fail "Widget entitlements missing"

grep -q "group.local.devpulse" "$APENT" 2>/dev/null && pass "App entitlements: App Group present" || fail "App entitlements: App Group missing"
grep -q "group.local.devpulse" "$WDENT" 2>/dev/null && pass "Widget entitlements: App Group present" || fail "Widget entitlements: App Group missing"

# App should NOT have sandbox; Widget should
if grep -q "app-sandbox" "$APENT" 2>/dev/null; then
    fail "App entitlements: has App Sandbox (should not)"
else
    pass "App entitlements: no App Sandbox"
fi
grep -q "app-sandbox" "$WDENT" 2>/dev/null && pass "Widget entitlements: has App Sandbox" || fail "Widget entitlements: missing App Sandbox"

# ── Built-app checks (if --app-path provided) ──
echo ""
echo "=== Built-app validation ==="
while [ $# -gt 0 ]; do
    case "$1" in --app-path) APP_PATH="$2"; shift 2 ;; *) shift ;; esac
done

if [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ]; then
    # Verify actual bundle IDs from the built app
    APP_BID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
    WDG_BID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/PlugIns/DevPulseWidgetExtension.appex/Contents/Info.plist" 2>/dev/null || true)
    APP_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)

    [ "$APP_BID" = "local.devpulse.app" ] && pass "Built app bundle ID: $APP_BID" || fail "Built app bundle ID: $APP_BID"
    [ "$WDG_BID" = "local.devpulse.app.widget" ] && pass "Built widget bundle ID: $WDG_BID" || fail "Built widget bundle ID: $WDG_BID"
    [ -n "$APP_VER" ] && pass "Built app version: $APP_VER" || fail "Built app version missing"

    # App Group consistency check
    CODESIGN_OUT=$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)
    echo "$CODESIGN_OUT" | grep -q "group.local.devpulse" && pass "Built app entitlements: App Group present" || fail "Built app entitlements: App Group not verified"

    # Widget extension embedded
    [ -d "$APP_PATH/Contents/PlugIns/DevPulseWidgetExtension.appex" ] && pass "Widget extension embedded in built app" || fail "Widget extension not embedded"
else
    skip "Built-app validation: no --app-path provided"
fi

echo ""
echo "=== Result: $PASS pass, $FAIL fail, $SKIP skip ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
