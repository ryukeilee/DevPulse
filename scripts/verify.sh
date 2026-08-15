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
# Environment:
#   DERIVED_DATA_PATH    Shared DerivedData path (default: /tmp/devpulse-build)
#   BUILD_TIMEOUT        Build timeout in seconds (default: 300)
#   TEST_TIMEOUT         Test timeout in seconds (default: 600)
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

COMMON_ARGS=(
    -project "$XCODEPROJ"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "$DESTINATION"
    -derivedDataPath "$DERIVED_DATA_PATH"
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
)

# ── helpers ──────────────────────────────────────────────────────────

info()  { printf '\033[36m[verify]\033[0m %s\n' "$*" >&2; }
ok()    { printf '\033[32m[verify]\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[31m[verify] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

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
    info "Building for testing (shared DerivedData: $DERIVED_DATA_PATH)…"
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

Workflow:
  1. Run 'verify.sh build' after checkout or modifying sources.
  2. Run 'verify.sh test DevPulseTests/SomeTest' repeatedly while iterating.
  3. At final acceptance, run 'verify.sh final' to build + run the full suite.

HELP
        exit 0
        ;;
    *)
        echo "Unknown command: $1" >&2
        echo "Usage: $0 {build|test|final|widgetkit|help}" >&2
        exit 2
        ;;
esac
