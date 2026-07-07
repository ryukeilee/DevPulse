#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/DevPulseNative"
XCODEPROJ="$PROJECT_DIR/DevPulseNative.xcodeproj"
SCHEME="DevPulse"
CONFIGURATION="Debug"
DESTINATION="platform=macOS"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/devpulse-build}"
BUILD_APP="$DERIVED_DATA_PATH/Build/Products/Debug/DevPulse.app"
INSTALL_APP="/Applications/DevPulse.app"
SNAPSHOT_FILE="$HOME/Library/Group Containers/group.local.devpulse/repositories.json"
SELF_CHECK_LOG="$(mktemp "${TMPDIR:-/tmp}/devpulse-self-check.XXXXXX.log")"
BACKUP_DIR=""
HOST_PROFILE_RELATIVE_PATH="Contents/embedded.provisionprofile"
WIDGET_PROFILE_RELATIVE_PATH="Contents/PlugIns/DevPulseWidgetExtension.appex/Contents/embedded.provisionprofile"

cleanup() {
    rm -f "$SELF_CHECK_LOG"
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        rm -rf "$BACKUP_DIR"
    fi
}

info() {
    printf '%s\n' "$1"
}

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

xcode_accounts_configured() {
    defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDs >/dev/null 2>&1 \
        || defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists >/dev/null 2>&1
}

first_apple_development_identity_line() {
    # Keep keychain access scoped to codesigning identities only.
    security find-identity -v -p codesigning \
        | sed -n '/Apple Development:/p' \
        | head -n 1
}

resolve_signing_identity() {
    if [ -n "${DEVPULSE_SIGNING_IDENTITY:-}" ]; then
        printf '%s\n' "$DEVPULSE_SIGNING_IDENTITY"
        return
    fi

    local identity_line identity
    identity_line="$(first_apple_development_identity_line)"
    identity="$(printf '%s\n' "$identity_line" | awk '{ print $2 }')"
    [ -n "$identity" ] || fail "No Apple Development signing identity found. Set DEVPULSE_SIGNING_IDENTITY to a certificate hash first."
    printf '%s\n' "$identity"
}

resolve_identity_team() {
    local identity_line team
    identity_line="$(first_apple_development_identity_line)"
    team="$(printf '%s\n' "$identity_line" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')"
    [ -n "$team" ] || fail "No Apple Development identity team could be derived on this Mac."
    printf '%s\n' "$team"
}

resolve_xcode_team() {
    local team
    team="$(
        plutil -p "$HOME/Library/Preferences/com.apple.dt.Xcode.plist" 2>/dev/null \
            | awk '/teamID/ { gsub(/"/, "", $3); print $3; exit }'
    )"
    [ -n "$team" ] || return 1
    printf '%s\n' "$team"
}

profile_team_for_bundle_id() {
    local bundle_id="$1"
    local tmp
    tmp="$(mktemp)"
    for profile in "$HOME"/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.provisionprofile; do
        [ -e "$profile" ] || continue
        security cms -D -i "$profile" > "$tmp" 2>/dev/null || continue
        local app_id team_id
        app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$tmp" 2>/dev/null || true)"
        if [ -z "$app_id" ]; then
            app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$tmp" 2>/dev/null || true)"
        fi
        case "$app_id" in
            *."$bundle_id")
                team_id="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$tmp" 2>/dev/null || true)"
                rm -f "$tmp"
                printf '%s\n' "$team_id"
                return 0
                ;;
        esac
    done
    rm -f "$tmp"
    return 1
}

verify_automatic_signing_prerequisites() {
    local expected_team host_profile_team widget_profile_team
    expected_team="$(resolve_xcode_team || resolve_identity_team)"
    host_profile_team="$(profile_team_for_bundle_id "local.devpulse.app" || true)"
    widget_profile_team="$(profile_team_for_bundle_id "local.devpulse.app.widget" || true)"

    if [ -n "$host_profile_team" ] && [ -n "$widget_profile_team" ] && [ "$host_profile_team" != "$widget_profile_team" ]; then
        fail "Local DevPulse host and widget provisioning profiles belong to different teams. Remove or regenerate the stale DevPulse profiles before retrying automatic signing."
    fi

    if [ -n "$host_profile_team" ] && [ "$host_profile_team" != "$expected_team" ]; then
        if ! xcode_accounts_configured; then
            fail "Local DevPulse provisioning profiles do not match the current Apple Development identity, and Xcode has no signed-in account to regenerate matching profiles."
        fi
        fail "Local DevPulse provisioning profiles do not match the active Xcode automatic-signing team. Regenerate or download fresh DevPulse profiles from the signed-in Xcode account before retrying."
    fi

    if ! xcode_accounts_configured; then
        fail "No Xcode Apple account is configured on this Mac. Automatic signing cannot regenerate the DevPulse host and widget provisioning profiles."
    fi
}

resolve_development_team() {
    if [ -n "${DEVPULSE_DEVELOPMENT_TEAM:-}" ]; then
        printf '%s\n' "$DEVPULSE_DEVELOPMENT_TEAM"
        return
    fi

    local configured_team identity_line team xcode_team
    configured_team="$(
        xcodebuild \
            -project "$XCODEPROJ" \
            -scheme "$SCHEME" \
            -showBuildSettings 2>/dev/null \
        | awk -F ' = ' '/^[[:space:]]*DEVELOPMENT_TEAM = / { print $2; exit }'
    )"
    if [ -n "$configured_team" ]; then
        printf '%s\n' "$configured_team"
        return
    fi

    xcode_team="$(resolve_xcode_team || true)"
    if [ -n "$xcode_team" ]; then
        printf '%s\n' "$xcode_team"
        return
    fi

    identity_line="$(first_apple_development_identity_line)"
    team="$(printf '%s\n' "$identity_line" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')"
    [ -n "$team" ] || fail "No Development Team found from signing identities. Set DEVPULSE_DEVELOPMENT_TEAM first."
    printf '%s\n' "$team"
}

stop_running_app() {
    local pids
    pids="$(pgrep -x DevPulse || true)"
    [ -z "$pids" ] && return

    info "Stopping existing DevPulse process"
    kill $pids || true

    local attempt
    for attempt in $(seq 1 40); do
        if ! pgrep -x DevPulse >/dev/null 2>&1; then
            return
        fi
        sleep 0.25
    done

    fail "Existing DevPulse process did not exit cleanly."
}

build_signed_app() {
    local team="$1"

    info "Building latest DevPulse.app with automatic signing"
    xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -destination "$DESTINATION" \
        DEVELOPMENT_TEAM="$team" \
        -allowProvisioningUpdates \
        build

    [ -d "$BUILD_APP" ] || fail "Build product not found at $BUILD_APP"
    [ -f "$BUILD_APP/$HOST_PROFILE_RELATIVE_PATH" ] \
        || fail "Built app is missing embedded.provisionprofile. Automatic signing did not produce a usable host app."
    [ -f "$BUILD_APP/$WIDGET_PROFILE_RELATIVE_PATH" ] \
        || fail "Built widget is missing embedded.provisionprofile. WidgetKit will be rejected on this machine."

    if [ -d "$BUILD_APP/Contents/PlugIns/DevPulseTests.xctest" ]; then
        info "Removing test bundle from app product before signing"
        mv "$BUILD_APP/Contents/PlugIns/DevPulseTests.xctest" \
            "${TMPDIR:-/tmp}/DevPulseTests.xctest.$$.bak"
    fi
    codesign --verify --deep --strict --verbose=2 "$BUILD_APP"
}

install_app() {
    if [ -d "$INSTALL_APP" ]; then
        BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-installed-backup.XXXXXX")"
        mv "$INSTALL_APP" "$BACKUP_DIR/DevPulse.app"
    fi

    info "Installing latest build to /Applications"
    ditto "$BUILD_APP" "$INSTALL_APP"
}

launch_installed_app() {
    info "Launching installed DevPulse.app"
    open -n "$INSTALL_APP"

    local attempt
    for attempt in $(seq 1 40); do
        if pgrep -x DevPulse >/dev/null 2>&1; then
            return
        fi
        sleep 0.25
    done

    fail "Installed DevPulse.app did not launch."
}

verify_running_process() {
    local pids
    pids="$(pgrep -x DevPulse || true)"
    [ -n "$pids" ] || fail "DevPulse is not running after launch."

    local count
    count="$(printf '%s\n' "$pids" | awk 'NF { count += 1 } END { print count + 0 }')"
    [ "$count" -eq 1 ] || fail "Expected exactly one DevPulse process after install, found $count."

    local pid command_path
    pid="$(printf '%s\n' "$pids" | awk 'NF { print; exit }')"
    command_path="$(ps -p "$pid" -o command= | sed 's/^ *//')"
    [ "$command_path" = "$INSTALL_APP/Contents/MacOS/DevPulse" ] \
        || fail "Running process is not the installed app: $command_path"

    local installed_hash built_hash
    installed_hash="$(shasum -a 256 "$INSTALL_APP/Contents/MacOS/DevPulse" | awk '{print $1}')"
    built_hash="$(shasum -a 256 "$BUILD_APP/Contents/MacOS/DevPulse" | awk '{print $1}')"
    [ "$installed_hash" = "$built_hash" ] || fail "Installed app hash does not match latest build hash."

    if [ -d "$INSTALL_APP/Contents/PlugIns/DevPulseTests.xctest" ]; then
        fail "Installed app still contains DevPulseTests.xctest."
    fi
}

run_self_check() {
    info "Running headless self-check"
    "$INSTALL_APP/Contents/MacOS/DevPulse" --self-check | tee "$SELF_CHECK_LOG"
    grep -q '^self_check.result=pass$' "$SELF_CHECK_LOG" || fail "Headless self-check reported failure."
}

verify_snapshot_matches_git() {
    [ -f "$SNAPSHOT_FILE" ] || fail "Shared snapshot file is missing at $SNAPSHOT_FILE"

    local repo_root actual_status snapshot_summary
    repo_root="$(cd "$ROOT_DIR" && git rev-parse --show-toplevel)"
    if [ -n "$(cd "$ROOT_DIR" && git status --short)" ]; then
        actual_status="changed"
    else
        actual_status="clean"
    fi

    snapshot_summary="$(python3 - "$SNAPSHOT_FILE" "$repo_root" <<'PY'
import json
import sys

snapshot_path, repo_root = sys.argv[1], sys.argv[2]
with open(snapshot_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

match = next((repo for repo in data.get("repositories", []) if repo.get("path") == repo_root), None)
if match is None:
    raise SystemExit("missing_repo")

print(data.get("generatedAt", ""))
print(data.get("writtenAt", ""))
print(match.get("status", ""))
print(match.get("changedFileCount", 0))
PY
)"

    [ "$snapshot_summary" != "missing_repo" ] || fail "Current repository was not found in the shared snapshot."

    local generated_at written_at snapshot_status changed_file_count
    generated_at="$(printf '%s\n' "$snapshot_summary" | sed -n '1p')"
    written_at="$(printf '%s\n' "$snapshot_summary" | sed -n '2p')"
    snapshot_status="$(printf '%s\n' "$snapshot_summary" | sed -n '3p')"
    changed_file_count="$(printf '%s\n' "$snapshot_summary" | sed -n '4p')"

    [ -n "$generated_at" ] || fail "Shared snapshot generatedAt is missing."
    [ -n "$written_at" ] || fail "Shared snapshot writtenAt is missing."
    [ "$snapshot_status" = "$actual_status" ] \
        || fail "Snapshot status for this repository is $snapshot_status, expected $actual_status."

    info "snapshot.generatedAt=$generated_at"
    info "snapshot.writtenAt=$written_at"
    info "snapshot.repoStatus=$snapshot_status"
    info "snapshot.changedFileCount=$changed_file_count"
}

main() {
    trap cleanup EXIT

    local identity team
    identity="$(resolve_signing_identity)"
    verify_automatic_signing_prerequisites
    team="$(resolve_development_team)"
    info "Using Apple Development signing identity: available"
    info "Using automatic signing team: resolved"

    build_signed_app "$team"
    stop_running_app
    install_app
    launch_installed_app
    verify_running_process
    run_self_check
    verify_running_process
    verify_snapshot_matches_git

    info "install_and_self_check=pass"
}

main "$@"
