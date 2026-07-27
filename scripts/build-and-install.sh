#!/usr/bin/env bash
# build-and-install.sh
#
# 在 Xcode 命令行无法自动 signing（无 Xcode accounts / free account）时，
# 用 codesign 手动签名构建并安装 DevPulse 到 /Applications。
#
# 用法:
#   ./scripts/build-and-install.sh              # 检测可用证书并构建安装
#   DEVPULSE_SIGNING_IDENTITY=<hash> ./scripts/build-and-install.sh   # 指定证书
#
# 环境变量:
#   DEVPULSE_SIGNING_IDENTITY  - codesign 身份（hash 或 "Apple Development: xxx"）
#   DERIVED_DATA_PATH          - DerivedData 路径（默认 /tmp/devpulse-build）

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

# ── helpers ──────────────────────────────────────────────────────────────

info()  { printf '\033[36m%s\033[0m\n' "$1"; }
ok()    { printf '\033[32m  ✓ %s\033[0m\n' "$1"; }
fail()  { printf '\033[31m  ✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ── resolve signing identity ─────────────────────────────────────────────

resolve_signing_identity() {
    if [ -n "${DEVPULSE_SIGNING_IDENTITY:-}" ]; then
        echo "$DEVPULSE_SIGNING_IDENTITY"
        return
    fi
    # 从 keychain 找到第一个 Apple Development 证书
    local line
    line="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n '/Apple Development:/{s/^[[:space:]]*[0-9]*)[[:space:]]*//;s/[[:space:]]*$//;p;q}')"
    [ -n "$line" ] || fail "No Apple Development signing identity found. Set DEVPULSE_SIGNING_IDENTITY."
    echo "$line"
}

resolve_team() {
    local identity="$1"
    # 从 "Apple Development: xxx (TEAMID)" 中提取 team ID
    echo "$identity" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p'
}

# ── stop_running_app ─────────────────────────────────────────────────────

stop_running_app() {
    local pids
    pids="$(pgrep -x DevPulse 2>/dev/null || true)"
    [ -z "$pids" ] && return

    info "Stopping running DevPulse…"
    kill "$pids" 2>/dev/null || true
    for _ in $(seq 1 20); do
        pgrep -x DevPulse >/dev/null 2>&1 || return 0
        sleep 0.25
    done
    fail "DevPulse did not exit."
}

# ── build unsigned ───────────────────────────────────────────────────────

build_unsigned() {
    info "Building (unsigned)…"
    xcodebuild -project "$XCODEPROJ" \
        -scheme "$SCHEME" -configuration "$CONFIGURATION" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        build 2>&1 | tail -5
    [ -d "$BUILD_APP" ] || fail "Build product not found at $BUILD_APP"
    ok "Build succeeded"
}

# ── sign manually ────────────────────────────────────────────────────────

sign_bundle() {
    local identity="$1"
    local team="$2"

    info "Signing…"

    local widget_path="$BUILD_APP/Contents/PlugIns/DevPulseWidgetExtension.appex"

    # 生成 entitlement plist（匹配项目定义）
    local app_entitlements="/tmp/devpulse-app-entitlements.plist"
    local widget_entitlements="/tmp/devpulse-widget-entitlements.plist"

    cat > "$app_entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.local.devpulse</string>
    </array>
</dict>
</plist>
PLIST

    cat > "$widget_entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.local.devpulse</string>
    </array>
</dict>
</plist>
PLIST

    # 先签 Widget Extension
    codesign --force --sign "$identity" \
        --entitlements "$widget_entitlements" \
        --verbose "$widget_path" 2>&1 | sed 's/^/  /'
    ok "Widget extension signed"

    # 签 App（含内置 Widget）
    codesign --force --sign "$identity" \
        --entitlements "$app_entitlements" \
        --verbose "$BUILD_APP" 2>&1 | sed 's/^/  /'
    ok "App signed"

    # 验证
    local app_team
    app_team="$(codesign -dvvv "$BUILD_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    local widget_team
    widget_team="$(codesign -dvvv "$widget_path" 2>&1 | sed -n 's/^TeamIdentifier=//p')"

    [ "$app_team" = "$widget_team" ] || fail "Team mismatch: app=$app_team widget=$widget_team"
    ok "Both targets signed with Team $app_team"
}

# ── install ──────────────────────────────────────────────────────────────

install_app() {
    info "Installing to $INSTALL_APP …"
    if [ -d "$INSTALL_APP" ]; then
        rm -rf "$INSTALL_APP"
    fi
    cp -R "$BUILD_APP" "$INSTALL_APP"
    ok "Installed"

    # 验证安装后的签名
    local app_team widget_team
    app_team="$(codesign -dvvv "$INSTALL_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    widget_team="$(codesign -dvvv "$INSTALL_APP/Contents/PlugIns/DevPulseWidgetExtension.appex" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    ok "Installed app Team=$app_team, Widget Team=$widget_team"
}

# ── launch ───────────────────────────────────────────────────────────────

launch_app() {
    info "Launching…"
    open "$INSTALL_APP"
    sleep 3
    if pgrep -x DevPulse >/dev/null 2>&1; then
        ok "App is running (PID $(pgrep -x DevPulse))"
    else
        fail "App failed to launch"
    fi
}

# ── main ─────────────────────────────────────────────────────────────────

main() {
    info "=== DevPulse Build & Install ==="

    local identity team
    identity="$(resolve_signing_identity)"
    team="$(resolve_team "$identity")"

    ok "Signing identity: $identity"
    ok "Team: $team"

    stop_running_app
    build_unsigned
    sign_bundle "$identity" "$team"
    install_app
    launch_app

    echo ""
    info "=== Done ==="
    echo "  App:      $INSTALL_APP"
    echo "  Widget:   $INSTALL_APP/Contents/PlugIns/DevPulseWidgetExtension.appex"
    echo "  Identity: $identity"
    echo "  Team:     $team"
    echo ""
    echo "检查 Widget 注册：log show --predicate 'process == \"DevPulseWidgetExtension\"' --last 5m"
}

main "$@"
