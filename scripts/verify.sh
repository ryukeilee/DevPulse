#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────
# DevPulse unified build & test verification script
#
# All operations share a single DerivedData cache (default: /tmp/devpulse-build).
# Build-for-testing compiles once; test-without-building reuses the pre-built
# bundle for repeated test runs with no recompilation.
#
# Usage:
#   ./scripts/verify.sh build                    # Compile once
#   ./scripts/verify.sh test [TestClass]         # Run tests (pre-built bundle)
#   ./scripts/verify.sh final                    # Build + full test suite
#   ./scripts/verify.sh widgetkit                # WidgetKit wiring check
#
# Examples:
#   ./scripts/verify.sh test DevPulseTests/ActivityEventTests
#   ./scripts/verify.sh test "DevPulseTests/CommitReadinessEngineTests/testStartupRefresh…()"
#
# Test environment (isolated scratch container):
#   The DevPulse host app declares the App Group entitlement
#   (com.apple.security.application-groups) in App/DevPulse.entitlements, and an
#   *unsigned* test host has no entitlement, so LaunchServices denies it access
#   to the real shared container. `test`/`final` therefore point the host at a
#   throwaway container and preferences suite via TEST_RUNNER_… environment
#   variables, so tests exercise the same read/write code without ever touching
#   the user's real App Group data. See docs/test-signing-modes.md.
#
# Environment:
#   DERIVED_DATA_PATH      Shared DerivedData path (default: /tmp/devpulse-build)
#   BUILD_TIMEOUT          Build timeout in seconds (default: 300)
#   TEST_TIMEOUT           Test timeout in seconds (default: 600)
#   DEVPULSE_SIGNING_MODE  auto (default) | signed | unsigned
#   DEVELOPMENT_TEAM       Explicit development team; implies signed mode
#   CODE_SIGN_IDENTITY     Signing identity name (default: Apple Development)
# ──────────────────────────────────────────────────────────────────────

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/DevPulseNative"
XCODEPROJ="$PROJECT_DIR/DevPulseNative.xcodeproj"
SCHEME="DevPulse"
CONFIGURATION="Debug"
DESTINATION="platform=macOS"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/devpulse-build}"
export DERIVED_DATA_PATH  # inherited by sub-scripts (verify-widgetkit.sh, etc.)
BUILD_TIMEOUT="${BUILD_TIMEOUT:-300}"
TEST_TIMEOUT="${TEST_TIMEOUT:-600}"

DEVPULSE_SIGNING_MODE="${DEVPULSE_SIGNING_MODE:-auto}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
APP_BUNDLE_ID="local.devpulse.app"
WIDGET_BUNDLE_ID="local.devpulse.app.widget"

COMMON_ARGS=(
    -project "$XCODEPROJ"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "$DESTINATION"
    -derivedDataPath "$DERIVED_DATA_PATH"
)

# ── helpers ──────────────────────────────────────────────────────────

info()  { printf '\033[36m[verify]\033[0m %s\n' "$*" >&2; }
ok()    { printf '\033[32m[verify]\033[0m %s\n' "$*" >&2; }
warn()  { printf '\033[33m[verify] WARNING:\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[31m[verify] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ── signing identity resolution ──────────────────────────────────────

# Team identifier of a locally installed provisioning profile for a bundle id.
profile_team_for_bundle_id() {
    local bundle_id="$1" profile tmp app_id team=""
    tmp="$(mktemp "${TMPDIR:-/tmp}/devpulse-profile.XXXXXX")"
    for profile in "$HOME"/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.provisionprofile; do
        [ -e "$profile" ] || continue
        security cms -D -i "$profile" >"$tmp" 2>/dev/null || continue
        app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$tmp" 2>/dev/null || true)"
        [ -n "$app_id" ] || continue
        case "$app_id" in
            *."$bundle_id")
                team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$tmp" 2>/dev/null || true)"
                [ -n "$team" ] && break
                ;;
        esac
    done
    rm -f "$tmp"
    [ -n "$team" ] || return 1
    printf '%s\n' "$team"
}

# Team identifier configured in Xcode's preferences (the signed-in account).
xcode_configured_team() {
    local team
    team="$(plutil -p "$HOME/Library/Preferences/com.apple.dt.Xcode.plist" 2>/dev/null \
        | awk '/teamID/ { gsub(/"/, "", $3); print $3; exit }')"
    [ -n "$team" ] || return 1
    printf '%s\n' "$team"
}

# Team identifier taken from the Apple Development certificate's OU field.
# NOTE: the value in parentheses in `security find-identity` output is a
# certificate identifier, NOT the team identifier — do not use it.
certificate_team() {
    local identity_name team
    identity_name="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
        | head -n 1)"
    [ -n "$identity_name" ] || return 1
    team="$(security find-certificate -c "$identity_name" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')"
    [ -n "$team" ] || return 1
    printf '%s\n' "$team"
}

# Resolve a usable development team, or return 1 when no signing is possible.
resolve_development_team() {
    local host_team widget_team team
    if [ -n "$DEVELOPMENT_TEAM" ]; then
        printf '%s\n' "$DEVELOPMENT_TEAM"
        return 0
    fi
    host_team="$(profile_team_for_bundle_id "$APP_BUNDLE_ID" || true)"
    widget_team="$(profile_team_for_bundle_id "$WIDGET_BUNDLE_ID" || true)"
    if [ -n "$host_team" ] && [ "$host_team" = "$widget_team" ]; then
        printf '%s\n' "$host_team"
        return 0
    fi
    team="$(xcode_configured_team || true)"
    [ -n "$team" ] || team="$(certificate_team || true)"
    [ -n "$team" ] || return 1
    printf '%s\n' "$team"
}

# Development team of local provisioning profiles matching BOTH bundle ids.
# This is what profile-based ("signed") builds actually need; certificate-only
# team resolution is not enough once the profile has expired.
local_profile_team() {
    local host_team widget_team
    host_team="$(profile_team_for_bundle_id "$APP_BUNDLE_ID" || true)"
    widget_team="$(profile_team_for_bundle_id "$WIDGET_BUNDLE_ID" || true)"
    [ -n "$host_team" ] && [ "$host_team" = "$widget_team" ] || return 1
    printf '%s\n' "$host_team"
}

# Decide the test environment and fold it into COMMON_ARGS.
#
# Tests run against an isolated scratch container (see setup_test_isolation),
# so signing is not required for them to pass. "auto" therefore uses
# profile-based signing only when local profiles for both bundle ids exist —
# certificate-only team resolution is not enough once a profile has expired —
# and stays unsigned otherwise.
SIGNING_MODE=""
RESOLVED_TEAM=""
case "$DEVPULSE_SIGNING_MODE" in
    auto)
        if [ -n "$DEVELOPMENT_TEAM" ]; then
            RESOLVED_TEAM="$(resolve_development_team)"
            SIGNING_MODE="signed"
        elif RESOLVED_TEAM="$(local_profile_team)"; then
            SIGNING_MODE="signed"
        else
            SIGNING_MODE="unsigned"
        fi
        ;;
    signed)
        RESOLVED_TEAM="$(resolve_development_team)" \
            || fail "DEVPULSE_SIGNING_MODE=signed but no development team could be resolved (set DEVELOPMENT_TEAM)."
        SIGNING_MODE="signed"
        ;;
    unsigned)
        SIGNING_MODE="unsigned"
        ;;
    *)
        fail "Unknown DEVPULSE_SIGNING_MODE='$DEVPULSE_SIGNING_MODE' (expected auto, signed, or unsigned)."
        ;;
esac

if [ "$SIGNING_MODE" = "signed" ]; then
    # No -allowProvisioningUpdates: the profile must already exist locally, so a
    # signed build stays deterministic and works without network access.
    COMMON_ARGS+=(
        DEVELOPMENT_TEAM="$RESOLVED_TEAM"
        CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Apple Development}"
    )
else
    # Unsigned test host. Tests are isolated from the real App Group (see
    # setup_test_isolation), so the entitlement is not needed.
    COMMON_ARGS+=(
        CODE_SIGNING_ALLOWED=NO
        CODE_SIGNING_REQUIRED=NO
    )
fi

report_test_environment() {
    if [ "$SIGNING_MODE" = "signed" ]; then
        info "Test environment: signed (team $RESOLVED_TEAM, identity ${CODE_SIGN_IDENTITY:-Apple Development})"
    else
        info "Test environment: unsigned (test host writes to an isolated scratch container)"
    fi
}

# Portable timeout wrapper: GNU coreutils `timeout` is not present on stock
# macOS < 15 (or in minimal PATH environments); fall back to running directly
# when it is unavailable so the documented entrypoint keeps working.
run_with_timeout() {
    local seconds="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
    else
        info "timeout not found in PATH; running without timeout enforcement"
        "$@"
    fi
}

# ── test isolation ───────────────────────────────────────────────────
#
# Tests must never read or write the user's real App Group container or
# preferences domain. The test host is launched by xcodebuild, which forwards
# every TEST_RUNNER_<VAR> variable to the host as <VAR>; the app reads the two
# overrides below through SharedSnapshotLocation / AppGroupStore.
ISOLATION_CONTAINER_PATH=""
ISOLATION_DEFAULTS_SUITE=""

cleanup_test_isolation() {
    if [ -n "$ISOLATION_DEFAULTS_SUITE" ]; then
        defaults delete "$ISOLATION_DEFAULTS_SUITE" >/dev/null 2>&1 || true
        rm -f "$HOME/Library/Preferences/$ISOLATION_DEFAULTS_SUITE.plist" 2>/dev/null || true
    fi
    if [ -n "$ISOLATION_CONTAINER_PATH" ]; then
        rm -rf "$ISOLATION_CONTAINER_PATH" 2>/dev/null || true
    fi
}
trap cleanup_test_isolation EXIT

setup_test_isolation() {
    ISOLATION_CONTAINER_PATH="$(mktemp -d "${TMPDIR:-/tmp}/devpulse-appgroup.XXXXXX")"
    ISOLATION_DEFAULTS_SUITE="local.devpulse.app.tests.$(uuidgen | tr 'A-Z' 'a-z')"
    export TEST_RUNNER_DEVPULSE_APP_GROUP_CONTAINER_PATH="$ISOLATION_CONTAINER_PATH"
    export TEST_RUNNER_DEVPULSE_APP_GROUP_DEFAULTS_SUITE="$ISOLATION_DEFAULTS_SUITE"
    info "Test isolation: container=$ISOLATION_CONTAINER_PATH defaults=$ISOLATION_DEFAULTS_SUITE"
}

# ── build-for-testing ────────────────────────────────────────────────

build_for_testing() {
    info "Building for testing (DerivedData: $DERIVED_DATA_PATH)…"
    report_test_environment
    local log_file
    log_file="$(mktemp "${TMPDIR:-/tmp}/devpulse-build.XXXXXX")"

    if run_with_timeout "$BUILD_TIMEOUT" xcodebuild \
        "${COMMON_ARGS[@]}" \
        build-for-testing \
        >"$log_file" 2>&1; then
        ok "Build succeeded"
        rm -f "$log_file"
    else
        echo "" >&2
        echo "══════════════ BUILD FAILURE (last 120 lines) ══════════════" >&2
        tail -n 120 "$log_file" >&2
        echo "════════════════════════════════════════════════════════════" >&2
        fail "Build failed — full log preserved: $log_file"
    fi
}

# ── test-without-building ────────────────────────────────────────────

run_tests() {
    local test_spec="${1:-}"
    local label="${2:-tests}"

    report_test_environment
    setup_test_isolation

    local test_args=("${COMMON_ARGS[@]}")
    if [ -n "$test_spec" ]; then
        test_args+=(-only-testing:"$test_spec")
        info "Running targeted test: $test_spec"
    else
        info "Running full test suite"
    fi

    local log_file
    log_file="$(mktemp "${TMPDIR:-/tmp}/devpulse-test.XXXXXX")"

    if run_with_timeout "$TEST_TIMEOUT" xcodebuild \
        "${test_args[@]}" \
        test-without-building \
        >"$log_file" 2>&1; then
        ok "$label passed"
        # Surface the totals so a passing run stays auditable.
        grep -E 'Test run with [0-9]+ tests? in [0-9]+ suites?|Executed [0-9]+ tests?, with [0-9]+ failures?' "$log_file" | tail -n 3 >&2 || true
        rm -f "$log_file"
    else
        echo "" >&2
        echo "══════════════ TEST FAILURE (last 200 lines) ═══════════════" >&2
        tail -n 200 "$log_file" >&2
        echo "════════════════════════════════════════════════════════════" >&2
        fail "$label failed — full log preserved: $log_file"
    fi
}

# ── command dispatch ─────────────────────────────────────────────────

case "${1:-help}" in
    build)
        build_for_testing
        ;;
    test)
        run_tests "${2:-}"
        ;;
    final)
        build_for_testing
        run_tests "" "full test suite"
        ok "Final acceptance passed — all checks green"
        ;;
    widgetkit)
        exec "$ROOT_DIR/scripts/verify-widgetkit.sh"
        ;;
    help|-h|--help)
        cat >&2 <<'HELP'
Usage: ./scripts/verify.sh <command> [options]

Commands:
  build                  Build for testing (compile once).
  test [TestClass]       Run tests against the pre-built bundle.
                         Omit TestClass to run the full suite.
                         Examples:
                           test DevPulseTests/ActivityEventTests
                           test DevPulseTests/CommitReadinessEngineTests
                           test DevPulseTests/SharedSnapshotStoreTests
  final                  Full acceptance gate: build + full test suite.
  widgetkit              WidgetKit wiring check (delegates to verify-widgetkit.sh).

Environment:
  DERIVED_DATA_PATH      Shared DerivedData path  (default: /tmp/devpulse-build)
  BUILD_TIMEOUT          Build timeout in seconds  (default: 300)
  TEST_TIMEOUT           Test timeout in seconds   (default: 600)
  DEVPULSE_SIGNING_MODE  Test environment selector:
                           auto      (default) use profile-based signing when
                                     local profiles for both bundle ids exist;
                                     otherwise unsigned (tests write to an
                                     isolated scratch container either way)
                           signed    profile-based signing; requires a local
                                     development team/profile (fails fast)
                           unsigned  unsigned test host (the default here)
  DEVELOPMENT_TEAM       Development team id; when set, signed mode is used
  CODE_SIGN_IDENTITY     Signing identity name (default: Apple Development)

Isolation:
  An unsigned test host would be denied access to the real shared container
  by LaunchServices, and tests must never modify the user's real App Group
  data. 'test'/'final' therefore point the host at a throwaway container and
  preferences suite (TEST_RUNNER_DEVPULSE_APP_GROUP_*), so the App Group tests
  pass unsigned while exercising the same on-disk read/write code. 'signed'
  mode remains available when local provisioning profiles are installed; see
  docs/test-signing-modes.md.

Workflow:
  1. Run 'verify.sh build' after checkout or modifying sources.
  2. Run 'verify.sh test DevPulseTests/SomeTest' repeatedly while iterating.
  3. At final acceptance, run 'verify.sh final' to build + run the full suite.
  4. The default 'auto' mode needs no signing identity or provisioning profile.

HELP
        exit 0
        ;;
    *)
        echo "Unknown command: $1" >&2
        echo "Usage: $0 {build|test|final|widgetkit|help}" >&2
        exit 2
        ;;
esac
