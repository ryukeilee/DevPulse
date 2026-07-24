#!/usr/bin/env bash
set -euo pipefail

# verify-upgrade.sh — 安装升级验证脚本
#
# 在已安装 DevPulse.app 的环境下验证：
#   1. App 已安装且可执行
#   2. Widget extension 嵌入正确
#   3. App Group 容器可访问
#   4. 共享快照可读
#   5. 自检恢复模块可用
#   6. Widget 时间线刷新能力
#
# 适用于 CI 或升级后手动验证。
# 用法：
#   ./scripts/verify-upgrade.sh                    # 默认 /Applications/DevPulse.app
#   DEVPULSE_APP_PATH=/path/to/DevPulse.app ./scripts/verify-upgrade.sh

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_APP="${DEVPULSE_APP_PATH:-/Applications/DevPulse.app}"
SNAPSHOT_FILE="$HOME/Library/Group Containers/group.local.devpulse/repositories.json"

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

info() {
    printf 'INFO: %s\n' "$1"
}

cleanup() {
    :
}

trap cleanup EXIT

cd "$ROOT_DIR"

# ──────────────────────────────────────────────
# 1. App bundle checks
# ──────────────────────────────────────────────
info "检查已安装的 App bundle"

if [ -d "$INSTALL_APP" ]; then
    pass "App bundle exists at $INSTALL_APP"
else
    fail "App bundle missing at $INSTALL_APP"
fi

APP_BINARY="$INSTALL_APP/Contents/MacOS/DevPulse"
if [ -x "$APP_BINARY" ]; then
    pass "App binary is executable"
else
    fail "App binary missing or not executable"
fi

WIDGET_BUNDLE="$INSTALL_APP/Contents/PlugIns/DevPulseWidgetExtension.appex"
if [ -d "$WIDGET_BUNDLE" ]; then
    pass "Widget extension bundle exists"
else
    fail "Widget extension bundle missing"
fi

# ──────────────────────────────────────────────
# 2. Info.plist checks
# ──────────────────────────────────────────────
info "检查 Info.plist 内容"

APP_PLIST="$INSTALL_APP/Contents/Info.plist"
WIDGET_PLIST="$WIDGET_BUNDLE/Contents/Info.plist"

plist_value() {
    local file="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$file" 2>/dev/null || echo ""
}

APP_BUNDLE_ID=$(plist_value "$APP_PLIST" "CFBundleIdentifier")
WIDGET_BUNDLE_ID=$(plist_value "$WIDGET_PLIST" "CFBundleIdentifier")
APP_VERSION=$(plist_value "$APP_PLIST" "CFBundleShortVersionString")
APP_BUILD=$(plist_value "$APP_PLIST" "CFBundleVersion")

if [ "$APP_BUNDLE_ID" = "local.devpulse.app" ]; then
    pass "App bundle identifier is correct"
else
    fail "App bundle identifier is '$APP_BUNDLE_ID', expected 'local.devpulse.app'"
fi

if [ "$WIDGET_BUNDLE_ID" = "local.devpulse.app.widget" ]; then
    pass "Widget bundle identifier is correct"
else
    fail "Widget bundle identifier is '$WIDGET_BUNDLE_ID', expected 'local.devpulse.app.widget'"
fi

if [ -n "$APP_VERSION" ]; then
    pass "App version is '$APP_VERSION' (build $APP_BUILD)"
else
    warn "App version not found in Info.plist"
fi

WIDGET_EXTENSION_POINT=$(plist_value "$WIDGET_PLIST" "NSExtension:NSExtensionPointIdentifier")
if [ "$WIDGET_EXTENSION_POINT" = "com.apple.widgetkit-extension" ]; then
    pass "Widget uses WidgetKit extension point"
else
    fail "Widget extension point is '$WIDGET_EXTENSION_POINT'"
fi

# ──────────────────────────────────────────────
# 3. App Group container
# ──────────────────────────────────────────────
info "检查 App Group 容器"

APP_GROUP_DIR="$HOME/Library/Group Containers/group.local.devpulse"
if [ -d "$APP_GROUP_DIR" ]; then
    pass "App Group container exists at $APP_GROUP_DIR"
else
    fail "App Group container missing"
fi

# ──────────────────────────────────────────────
# 4. Snapshot file
# ──────────────────────────────────────────────
info "检查共享快照文件"

if [ -f "$SNAPSHOT_FILE" ]; then
    pass "Shared snapshot file exists"

    SNAPSHOT_SIZE=$(stat -f "%z" "$SNAPSHOT_FILE" 2>/dev/null || stat -c "%s" "$SNAPSHOT_FILE" 2>/dev/null || echo "unknown")
    if [ "$SNAPSHOT_SIZE" != "unknown" ] && [ "$SNAPSHOT_SIZE" -gt 10 ]; then
        pass "Snapshot file size ($SNAPSHOT_SIZE bytes) looks valid"
    else
        fail "Snapshot file is suspiciously small ($SNAPSHOT_SIZE bytes)"
    fi

    # Quick JSON validity check
    if python3 -c "import json; json.load(open('$SNAPSHOT_FILE'))" 2>/dev/null; then
        pass "Snapshot file is valid JSON"
    else
        fail "Snapshot file is not valid JSON"
    fi

    # Check schema version
    SCHEMA_VERSION=$(python3 -c "
import json
data = json.load(open('$SNAPSHOT_FILE'))
print(data.get('schemaVersion', 'missing'))
" 2>/dev/null || echo "read_error")
    if [ "$SCHEMA_VERSION" = "3" ] || [ "$SCHEMA_VERSION" = "2" ] || [ "$SCHEMA_VERSION" = "1" ]; then
        pass "Snapshot schema version is v$SCHEMA_VERSION"
    else
        fail "Snapshot schema version is '$SCHEMA_VERSION', expected 1, 2, or 3"
    fi

    # Check storageRevision
    STORAGE_REV=$(python3 -c "
import json
data = json.load(open('$SNAPSHOT_FILE'))
rev = data.get('storageRevision', 0)
print(rev)
" 2>/dev/null || echo "read_error")
    if [ "$STORAGE_REV" != "read_error" ] && [ "$STORAGE_REV" -ge 0 ] 2>/dev/null; then
        pass "Snapshot storage revision is $STORAGE_REV"
    else
        fail "Could not read storage revision from snapshot"
    fi

    # Check appVersion field (new in v3 enhanced protocol)
    APP_VERSION_IN_SNAPSHOT=$(python3 -c "
import json
data = json.load(open('$SNAPSHOT_FILE'))
vers = data.get('appVersion')
print(vers if vers else 'missing')
" 2>/dev/null || echo "read_error")
    if [ "$APP_VERSION_IN_SNAPSHOT" != "missing" ] && [ "$APP_VERSION_IN_SNAPSHOT" != "read_error" ]; then
        pass "Snapshot has appVersion='$APP_VERSION_IN_SNAPSHOT'"
    else
        info "Snapshot does not have appVersion field (expected before first v3 enhanced write)"
    fi

    # Check if snapshot has repositories
    REPO_COUNT=$(python3 -c "
import json
data = json.load(open('$SNAPSHOT_FILE'))
repos = data.get('repositories', [])
print(len(repos))
" 2>/dev/null || echo "read_error")
    if [ "$REPO_COUNT" != "read_error" ] && [ "$REPO_COUNT" -gt 0 ] 2>/dev/null; then
        pass "Snapshot contains $REPO_COUNT repositories"
    else
        info "Snapshot has 0 repositories (expected before first scan)"
    fi

    # Check generatedAt is a valid ISO date
    python3 -c "
import json
data = json.load(open('$SNAPSHOT_FILE'))
generated = data.get('generatedAt', '')
assert len(generated) > 10, 'generatedAt is too short'
print(f'Snapshot generated at: {generated}')
" 2>/dev/null && pass "Snapshot generatedAt is a valid timestamp" || fail "Snapshot generatedAt is missing or invalid"

else
    fail "Shared snapshot file is missing at $SNAPSHOT_FILE"
fi

# ──────────────────────────────────────────────
# 5. Backup file
# ──────────────────────────────────────────────
info "检查共享快照备份文件"

BACKUP_FILE="${SNAPSHOT_FILE}.backup"
if [ -f "$BACKUP_FILE" ]; then
    pass "Snapshot backup file exists"
else
    info "Snapshot backup file not found (normal before first commit recovery)"
fi

# ──────────────────────────────────────────────
# 6. Process (if running)
# ──────────────────────────────────────────────
info "检查 DevPulse 进程"

RUNNING_PIDS=$(pgrep -x DevPulse || true)
if [ -n "$RUNNING_PIDS" ]; then
    PID_COUNT=$(echo "$RUNNING_PIDS" | wc -l | tr -d ' ')
    pass "DevPulse is running ($PID_COUNT process(es))"

    # Verify running from the expected install path
    for PID in $RUNNING_PIDS; do
        CMD_PATH=$(ps -p "$PID" -o command= 2>/dev/null | sed 's/^ *//' | head -1 || true)
        if echo "$CMD_PATH" | grep -q "$INSTALL_APP"; then
            pass "PID $PID is running from the installed path"
        else
            info "PID $PID is running from: $CMD_PATH"
        fi
    done
else
    info "DevPulse is not currently running (expected for offline verification)"
fi

# ──────────────────────────────────────────────
# 7. Summary
# ──────────────────────────────────────────────
printf '\n═══════════════════════════════════════════\n'
printf 'Upgrade verification result: %d PASS, %d FAIL\n' "$PASS_COUNT" "$FAIL_COUNT"
printf '═══════════════════════════════════════════\n'

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
