#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/DevPulseNative"
XCODEPROJ="$PROJECT_DIR/DevPulseNative.xcodeproj"
PBXPROJ="$XCODEPROJ/project.pbxproj"
SCHEME="DevPulse"
CONFIGURATION="Debug"
DESTINATION="platform=macOS"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/devpulse-build}"
APP_ENTITLEMENTS_FILE="$PROJECT_DIR/App/DevPulse.entitlements"
WIDGET_ENTITLEMENTS_FILE="$PROJECT_DIR/Widget/DevPulseWidgetExtension.entitlements"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    printf 'PASS: %s\n' "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

require_file_contains() {
    local file="$1"
    local needle="$2"
    local label="$3"
    if grep -Fq "$needle" "$file"; then
        pass "$label"
    else
        fail "$label"
    fi
}

plist_value() {
    local file="$1"
    local key_path="$2"
    /usr/libexec/PlistBuddy -c "Print :$key_path" "$file" 2>/dev/null || true
}

check_entitlement_file() {
    local file="$1"
    local entitlement_key="$2"
    local expected_value="$3"
    local label="$4"

    if [ ! -f "$file" ]; then
        fail "$label"
        printf '      missing file: %s\n' "$file" >&2
    else
        local actual_value
        actual_value="$(plist_value "$file" "$entitlement_key")"
        if [ "$actual_value" = "$expected_value" ]; then
            pass "$label"
        else
            fail "$label"
            printf '      expected: %s\n' "$expected_value" >&2
            printf '      actual:   %s\n' "${actual_value:-<missing>}" >&2
        fi
    fi
}

check_pbxproj_contains() {
    local needle="$1"
    local label="$2"
    if grep -Fq "$needle" "$PBXPROJ"; then
        pass "$label"
    else
        fail "$label"
    fi
}

cd "$ROOT_DIR"

build_log="$(mktemp "${TMPDIR:-/tmp}/devpulse-widgetkit-build.XXXXXX.log")"
if xcodebuild \
    -project "$XCODEPROJ" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build >"$build_log" 2>&1; then
    pass "xcodebuild Debug build"
else
    fail "xcodebuild Debug build"
    tail -n 120 "$build_log" >&2 || cat "$build_log" >&2
    rm -f "$build_log"
    exit 1
fi
rm -f "$build_log"

build_settings_log="$(mktemp "${TMPDIR:-/tmp}/devpulse-widgetkit-settings.XXXXXX.log")"
if xcodebuild \
    -project "$XCODEPROJ" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -showBuildSettings >"$build_settings_log" 2>&1; then
    BUILT_PRODUCTS_DIR="$(awk -F ' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR = / { print $2; exit }' "$build_settings_log")"
else
    fail "showBuildSettings"
    tail -n 120 "$build_settings_log" >&2 || cat "$build_settings_log" >&2
    rm -f "$build_settings_log"
    exit 1
fi
rm -f "$build_settings_log"

APP_BUNDLE="$BUILT_PRODUCTS_DIR/DevPulse.app"
WIDGET_BUNDLE="$BUILT_PRODUCTS_DIR/DevPulseWidgetExtension.appex"
APP_INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
WIDGET_INFO_PLIST="$WIDGET_BUNDLE/Contents/Info.plist"

if [ -d "$APP_BUNDLE" ]; then
    pass "app bundle exists"
else
    fail "app bundle exists"
fi

if [ -d "$WIDGET_BUNDLE" ]; then
    pass "widget bundle exists"
else
    fail "widget bundle exists"
fi

if [ -d "$APP_BUNDLE/Contents/PlugIns/DevPulseWidgetExtension.appex" ]; then
    pass "widget is embedded in the app bundle"
else
    fail "widget is embedded in the app bundle"
fi

app_bundle_id="$(plist_value "$APP_INFO_PLIST" CFBundleIdentifier)"
widget_bundle_id="$(plist_value "$WIDGET_INFO_PLIST" CFBundleIdentifier)"
widget_extension_point="$(plist_value "$WIDGET_INFO_PLIST" NSExtension:NSExtensionPointIdentifier)"
widget_app_bundle_id="$(plist_value "$WIDGET_INFO_PLIST" NSExtension:NSExtensionAttributes:WKAppBundleIdentifier)"

if [ "$app_bundle_id" = "local.devpulse.app" ]; then
    pass "app bundle identifier matches"
else
    fail "app bundle identifier matches"
    printf '      actual: %s\n' "${app_bundle_id:-<missing>}" >&2
fi

if [ "$widget_bundle_id" = "local.devpulse.app.widget" ]; then
    pass "widget bundle identifier matches"
else
    fail "widget bundle identifier matches"
    printf '      actual: %s\n' "${widget_bundle_id:-<missing>}" >&2
fi

if [ "$widget_extension_point" = "com.apple.widgetkit-extension" ]; then
    pass "widget plist uses WidgetKit extension point"
else
    fail "widget plist uses WidgetKit extension point"
    printf '      actual: %s\n' "${widget_extension_point:-<missing>}" >&2
fi

if [ "$widget_app_bundle_id" = "local.devpulse.app" ]; then
    pass "WKAppBundleIdentifier points to the app bundle"
else
    fail "WKAppBundleIdentifier points to the app bundle"
    printf '      actual: %s\n' "${widget_app_bundle_id:-<missing>}" >&2
fi

check_entitlement_file "$APP_ENTITLEMENTS_FILE" "com.apple.security.application-groups:0" "group.local.devpulse" "app entitlements include the shared App Group"
check_entitlement_file "$WIDGET_ENTITLEMENTS_FILE" "com.apple.security.application-groups:0" "group.local.devpulse" "widget entitlements include the shared App Group"

check_pbxproj_contains "DevPulseWidgetExtension.appex in Embed Foundation Extensions" "project embeds the widget extension"
check_pbxproj_contains "remoteInfo = DevPulseWidgetExtension" "project declares the widget target dependency"
check_pbxproj_contains "PRODUCT_BUNDLE_IDENTIFIER = local.devpulse.app;" "project sets the app bundle identifier"
check_pbxproj_contains "PRODUCT_BUNDLE_IDENTIFIER = local.devpulse.app.widget;" "project sets the widget bundle identifier"
check_pbxproj_contains "APP_BUNDLE_ID = local.devpulse.app;" "project passes the app bundle id to the widget"

if [ "$FAIL_COUNT" -gt 0 ]; then
    printf 'WidgetKit verification failed: %d PASS, %d FAIL\n' "$PASS_COUNT" "$FAIL_COUNT" >&2
    exit 1
fi

printf 'WidgetKit verification passed: %d PASS, %d FAIL\n' "$PASS_COUNT" "$FAIL_COUNT"
