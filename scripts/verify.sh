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
# Test environment (signed vs unsigned):
#   The DevPulse host app declares the App Group entitlement
#   (com.apple.security.application-groups) in App/DevPulse.entitlements. Tests
#   that exercise the shared snapshot container only keep that access when the
#   test host is signed with a matching development identity; an unsigned /
#   entitlement-less bundle is denied access by LaunchServices even though the
#   container path still resolves. See docs/test-signing-modes.md.
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

warn_unsigned_known_failures() {
    warn "Running the test host WITHOUT the App Group entitlement (unsigned mode)."
    warn "These tests access the shared container through LaunchServices and are"
    warn "expected to fail here — they are environment artefacts, not regressions:"
    warn "  RefreshCompletionTests.initialStateIsIdle()"
    warn "  RepositoryDiscoveryExperienceTests.schedulerRebuildMigratesLegacyPinsAndSharedSnapshotIdentity()"
    warn "  RepositoryDiscoveryExperienceTests.schedulerRebuildMigratesIgnoredPathsAndRewritesSharedSnapshotScope()"
    warn "  RepositoryDiscoveryExperienceTests.ignoringRepositoryImmediatelyFiltersAppAndSharedWidgetSnapshotAndForcesScopedScan()"
    warn "  RepositoryDiscoveryExperienceTests.repositoryRetryAfterBackupRecoveryCommitsAWidgetReadableSnapshot()"
    warn "Run with DEVPULSE_SIGNING_MODE=signed (or DEVELOPMENT_TEAM=<team>) to exercise them."
}

# Decide the test environment and fold it into COMMON_ARGS.
# Default (auto): sign when a development identity can be resolved, otherwise
# keep the previous unsigned behaviour so machines without a certificate (CI)
# are no worse off than before.
SIGNING_MODE=""
RESOLVED_TEAM=""
case "$DEVPULSE_SIGNING_MODE" in
    auto)
        if RESOLVED_TEAM="$(resolve_development_team)"; then
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
    COMMON_ARGS+=(
        CODE_SIGNING_ALLOWED=NO
        CODE_SIGNING_REQUIRED=NO
    )
fi

report_test_environment() {
    if [ "$SIGNING_MODE" = "signed" ]; then
        info "Test environment: signed (team $RESOLVED_TEAM, identity ${CODE_SIGN_IDENTITY:-Apple Development})"
    else
        info "Test environment: unsigned (mode '$DEVPULSE_SIGNING_MODE')"
        warn_unsigned_known_failures
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
                           auto      (default) sign when an Apple Development
                                     identity can be resolved locally; otherwise
                                     fall back to unsigned and warn about the
                                     known App Group entitlement failures
                           signed    require a development identity (fails fast
                                     when none is resolvable)
                           unsigned  force the entitlement-less environment
  DEVELOPMENT_TEAM       Development team id; when set, signed mode is used
  CODE_SIGN_IDENTITY     Signing identity name (default: Apple Development)

Signing:
  The host app declares com.apple.security.application-groups. An unsigned
  test host has no entitlements, so container access is denied even though the
  path resolves — that is what makes a handful of shared-container tests fail.
  Signed mode needs the team plus the local provisioning profiles; see
  docs/test-signing-modes.md.

Workflow:
  1. Run 'verify.sh build' after checkout or modifying sources.
  2. Run 'verify.sh test DevPulseTests/SomeTest' repeatedly while iterating.
  3. At final acceptance, run 'verify.sh final' to build + run the full suite.
  4. On a machine without a signing identity the default 'auto' mode keeps
     working exactly as before (unsigned) and prints the known-failure note.

HELP
        exit 0
        ;;
    *)
        echo "Unknown command: $1" >&2
        echo "Usage: $0 {build|test|final|widgetkit|help}" >&2
        exit 2
        ;;
esac
