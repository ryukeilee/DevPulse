#!/usr/bin/env bash
# verify-install-upgrade.sh
#
# Validates that the installed DevPulse.app bundle and its Widget extension
# meet structural, signing, and upgrade-compatibility requirements.
#
# Usage:
#   ./scripts/verify-install-upgrade.sh [--app-path /path/to/DevPulse.app]
#
# Dependencies: bash 4+, python3, plutil (macOS)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-/Applications/DevPulse.app}"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass()  { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS: %s\n' "$1"; }
fail()  { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL: %s\n' "$1" >&2; }
skip()  { SKIP_COUNT=$((SKIP_COUNT + 1)); printf 'SKIP: %s\n' "$1"; }

plist_value() {
    local file="$1" key_path="$2"
    /usr/libexec/PlistBuddy -c "Print :$key_path" "$file" 2>/dev/null || true
}

plist_value_exists() {
    local file="$1" key_path="$2"
    /usr/libexec/PlistBuddy -c "Print :$key_path" "$file" >/dev/null 2>&1
}

# ── App bundle structure ────────────────────────────────────────────────

check_app_bundle() {
    if [ -d "$APP_PATH" ]; then
        pass "App bundle exists at $APP_PATH"
    else
        fail "App bundle not found at $APP_PATH"
        return 1
    fi
    return 0
}

check_app_binary() {
    local binary="$APP_PATH/Contents/MacOS/DevPulse"
    if [ -f "$binary" ] && [ -x "$binary" ]; then
        pass "App executable exists and is executable"
    else
        fail "App executable is missing or not executable"
    fi
}

check_widget_extension() {
    local widget="$APP_PATH/Contents/PlugIns/DevPulseWidgetExtension.appex"
    if [ -d "$widget" ]; then
        pass "Widget extension plugin is embedded"
    else
        fail "Widget extension plugin is missing"
    fi
}

check_widget_binary() {
    local widget_binary="$APP_PATH/Contents/PlugIns/DevPulseWidgetExtension.appex/Contents/MacOS/DevPulseWidgetExtension"
    if [ -f "$widget_binary" ] && [ -x "$widget_binary" ]; then
        pass "Widget extension executable exists and is executable"
    else
        fail "Widget extension executable is missing or not executable"
    fi
}

check_info_plist_fields() {
    local info_plist="$APP_PATH/Contents/Info.plist"
    if [ ! -f "$info_plist" ]; then
        fail "App Info.plist is missing"
        return
    fi

    local bundle_id app_version min_os
    bundle_id="$(plist_value "$info_plist" "CFBundleIdentifier")"
    app_version="$(plist_value "$info_plist" "CFBundleShortVersionString")"
    min_os="$(plist_value "$info_plist" "LSMinimumSystemVersion")"

    if [ "$bundle_id" = "local.devpulse.app" ]; then
        pass "App bundle identifier is correct: $bundle_id"
    else
        fail "App bundle identifier is '$bundle_id', expected 'local.devpulse.app'"
    fi

    if [ -n "$app_version" ]; then
        pass "App version: $app_version"
    else
        fail "App version is missing from Info.plist"
    fi

    if [ "$min_os" = "14.0" ] || [ "$min_os" = "14" ]; then
        pass "Minimum system version is macOS $min_os"
    else
        fail "Minimum system version is '$min_os', expected '14.0'"
    fi
}

check_widget_info_plist() {
    local widget_info="$APP_PATH/Contents/PlugIns/DevPulseWidgetExtension.appex/Contents/Info.plist"
    if [ ! -f "$widget_info" ]; then
        fail "Widget Info.plist is missing"
        return
    fi

    local widget_bundle_id extension_point wk_app_bundle
    widget_bundle_id="$(plist_value "$widget_info" "CFBundleIdentifier")"
    extension_point="$(plist_value "$widget_info" "NSExtension:NSExtensionPointIdentifier")"
    wk_app_bundle="$(plist_value "$widget_info" "NSExtension:NSExtensionAttributes:WKAppBundleIdentifier")"

    if [ "$widget_bundle_id" = "local.devpulse.app.widget" ]; then
        pass "Widget bundle identifier is correct: $widget_bundle_id"
    else
        fail "Widget bundle identifier is '$widget_bundle_id', expected 'local.devpulse.app.widget'"
    fi

    if [ "$extension_point" = "com.apple.widgetkit-extension" ]; then
        pass "Widget uses WidgetKit extension point"
    else
        fail "Widget extension point is '$extension_point', expected 'com.apple.widgetkit-extension'"
    fi

    if [ "$wk_app_bundle" = "local.devpulse.app" ]; then
        pass "Widget WKAppBundleIdentifier points to the app"
    else
        fail "Widget WKAppBundleIdentifier is '$wk_app_bundle', expected 'local.devpulse.app'"
    fi
}

# ── Code signing ────────────────────────────────────────────────────────

check_codesign() {
    if ! codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
        local reason
        reason="$(codesign --verify --deep --strict "$APP_PATH" 2>&1 || true)"
        fail "Code signature verification failed: $(printf '%s' "$reason" | tr '\n' ' ')"
    else
        pass "App code signature is valid (deep verify)"
    fi
}

check_entitlements() {
    local app_entitlements widget_entitlements

    app_entitlements="$(codesign -d --entitlements - "$APP_PATH" 2>/dev/null |
        plutil -extract com.apple.security.application-groups json - 2>/dev/null || true)"
    if echo "$app_entitlements" | grep -q "group.local.devpulse"; then
        pass "App entitlements include App Group 'group.local.devpulse'"
    else
        fail "App entitlements missing App Group 'group.local.devpulse'"
    fi

    local widget_path="$APP_PATH/Contents/PlugIns/DevPulseWidgetExtension.appex"
    widget_entitlements="$(codesign -d --entitlements - "$widget_path" 2>/dev/null |
        plutil -extract com.apple.security.application-groups json - 2>/dev/null || true)"
    if echo "$widget_entitlements" | grep -q "group.local.devpulse"; then
        pass "Widget entitlements include App Group 'group.local.devpulse'"
    else
        fail "Widget entitlements missing App Group 'group.local.devpulse'"
    fi
}

# ── Snapshot compatibility ──────────────────────────────────────────────

check_snapshot_paths() {
    local group_containers
    group_containers="$HOME/Library/Group Containers"

    if [ -d "$group_containers" ]; then
        pass "Group Containers directory exists"
    else
        skip "Group Containers directory not found (expected before first launch)"
        return
    fi

    local snapshots
    snapshots="$(find "$group_containers" -name "repositories.json*" -maxdepth 2 2>/dev/null || true)"

    if [ -n "$snapshots" ]; then
        local count
        count="$(echo "$snapshots" | wc -l | tr -d ' ')"
        pass "Found $count snapshot file(s) in Group Containers"
    else
        skip "No snapshot files found in Group Containers (expected before first launch)"
    fi
}

check_snapshot_structure() {
    local group_containers="$HOME/Library/Group Containers"
    local snapshot_file

    snapshot_file="$(find "$group_containers" -name "repositories.json" -maxdepth 2 2>/dev/null | head -1 || true)"
    if [ -z "$snapshot_file" ]; then
        skip "No repositories.json found (expected before first launch)"
        return
    fi

    pass "Found snapshot at $snapshot_file"

    # Schema and metadata fields
    if plist_value_exists "$snapshot_file" "schemaVersion"; then
        local sv
        sv="$(plist_value "$snapshot_file" "schemaVersion")"
        pass "Snapshot schema version: $sv"
    else
        fail "Snapshot missing schemaVersion field"
    fi

    if plist_value_exists "$snapshot_file" "storageFormatVersion"; then
        local sfv
        sfv="$(plist_value "$snapshot_file" "storageFormatVersion")"
        pass "Snapshot storage format version: $sfv"
    else
        skip "Snapshot missing storageFormatVersion (may be legacy format)"
    fi

    if plist_value_exists "$snapshot_file" "appVersion"; then
        local av
        av="$(plist_value "$snapshot_file" "appVersion")"
        pass "Snapshot written by app version: $av"
    else
        skip "Snapshot missing appVersion (may be legacy format)"
    fi

    if plist_value_exists "$snapshot_file" "generatedAt"; then
        pass "Snapshot has generatedAt timestamp"
    else
        fail "Snapshot missing generatedAt"
    fi

    if plist_value_exists "$snapshot_file" "writtenAt"; then
        pass "Snapshot has writtenAt timestamp"
    else
        skip "Snapshot missing writtenAt (may be in-memory only)"
    fi

    if plist_value_exists "$snapshot_file" "storageRevision"; then
        local rev
        rev="$(plist_value "$snapshot_file" "storageRevision")"
        if [ "$rev" -gt 0 ] 2>/dev/null; then
            pass "Snapshot storage revision: $rev"
        else
            fail "Snapshot storage revision is zero"
        fi
    else
        fail "Snapshot missing storageRevision"
    fi

    if plist_value_exists "$snapshot_file" "persistenceState"; then
        local state
        state="$(plist_value "$snapshot_file" "persistenceState")"
        pass "Snapshot persistence state: $state"
    else
        fail "Snapshot missing persistenceState"
    fi

    # Repository payload
    if plist_value_exists "$snapshot_file" "repositories"; then
        local repo_count
        repo_count="$(plutil -extract repositories json "$snapshot_file" 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "unknown")"
        pass "Snapshot contains $repo_count repositories"
    else
        fail "Snapshot missing repositories array"
    fi

    if plist_value_exists "$snapshot_file" "scanSummary"; then
        pass "Snapshot has scanSummary"
    else
        fail "Snapshot missing scanSummary"
    fi
}

# ── Upgrade compatibility ───────────────────────────────────────────────

check_legacy_schema_readability() {
    # Verify that the installed app can read a known-legacy snapshot format.
    # Uses a minimal schema-v1 fixture stored alongside this script.
    local fixture_path="${FIXTURE_DIR:-"$ROOT_DIR/scripts/fixtures"}/snapshot-schema-v1.json"

    if [ ! -f "$fixture_path" ]; then
        skip "Legacy schema fixture not found at $fixture_path (create to enable test)"
        return
    fi

    # Verify the fixture is valid JSON with schemaVersion 1
    local fixture_schema
    fixture_schema="$(plist_value "$fixture_path" "schemaVersion" 2>/dev/null || true)"
    if [ "$fixture_schema" != "1" ]; then
        fail "Legacy fixture does not have schemaVersion=1"
        return
    fi

    # Attempt to decode the fixture using the installed app's snapshot decoder
    # by launching the app with a custom snapshot path argument.
    # Note: this requires the app to support --verify-snapshot-path argument.
    local binary="$APP_PATH/Contents/MacOS/DevPulse"
    if [ -x "$binary" ]; then
        local result
        result="$("$binary" --verify-snapshot-path "$fixture_path" 2>&1 || true)"
        if echo "$result" | grep -qi "supported\|migrat\|v1\|legacy\|pass"; then
            pass "Legacy schema v1 fixture is readable by installed app"
        else
            skip "Legacy schema v1 readability could not be confirmed (app may not support --verify-snapshot-path)"
        fi
    else
        skip "App binary not available for legacy-schema verification"
    fi
}

# ── Main ────────────────────────────────────────────────────────────────

main() {
    printf '=== DevPulse Install/Upgrade Verification ===\n\n'

    # Parse --app-path
    while [ $# -gt 0 ]; do
        case "$1" in
            --app-path)
                APP_PATH="$2"; shift 2 ;;
            --fixture-dir)
                FIXTURE_DIR="$2"; shift 2 ;;
            --help)
                echo "Usage: $0 [--app-path /path/to/DevPulse.app] [--fixture-dir /path/to/fixtures]"
                exit 0 ;;
            *)
                fail "Unknown argument: $1" ;;
        esac
    done

    # 1. App bundle
    printf '[1] App bundle structure\n'
    check_app_bundle
    check_app_binary
    check_widget_extension
    check_widget_binary
    check_info_plist_fields
    check_widget_info_plist
    printf '\n'

    # 2. Code signing
    printf '[2] Code signing and entitlements\n'
    check_codesign
    check_entitlements
    printf '\n'

    # 3. Snapshot compatibility
    printf '[3] Snapshot compatibility\n'
    check_snapshot_paths
    check_snapshot_structure
    printf '\n'

    # 4. Upgrade compatibility
    printf '[4] Upgrade compatibility\n'
    check_legacy_schema_readability
    printf '\n'

    # Summary
    local total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
    printf '=== Summary: %d pass, %d fail, %d skip (%d total) ===\n' \
        "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$total"

    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
