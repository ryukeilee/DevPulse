#!/usr/bin/env bash
# build-and-install.sh — 通用 macOS 原生 App 构建签名安装脚本
#
# 自动适配 DevPulse / TinyBuddy / Codex Monitor Native Prototype 三个项目。
# 构建 -> 嵌入 provisionprofile -> 使用正确 entitlements 签名 -> 安装 -> 启动。
#
# 用法:
#   ./script/build-and-install.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_NAME="$(basename "$ROOT_DIR")"

PROJECT="${PROJECT:-}"
[ -n "$PROJECT" ] || case "$REPO_NAME" in
  DevPulse)                         PROJECT="DevPulse" ;;
  TinyBuddy)                        PROJECT="TinyBuddy" ;;
  "Codex Monitor Native Prototype") PROJECT="CodexMonitor" ;;
  *) echo "ERROR: Set PROJECT=DevPulse|TinyBuddy|CodexMonitor" >&2; exit 1 ;;
esac

# ── 项目配置 ──────────────────────────────────────────────────
case "$PROJECT" in
  DevPulse)
    APP_NAME="DevPulse"
    XCODEPROJ_REL="DevPulseNative/DevPulseNative.xcodeproj"
    SCHEME="DevPulse"
    BUNDLE_ID="local.devpulse.app"
    APP_GROUP="group.local.devpulse"
    DERIVED_DATA_SUFFIX="devpulse-build"
    ENTITLEMENTS_APP="DevPulseNative/App/DevPulse.entitlements"
    ENTITLEMENTS_WIDGET="DevPulseNative/Widget/DevPulseWidgetExtension.entitlements"
    PROFILE_UUID_HOST="a2f128d6-ae72-41cd-85e4-fd9fb5ffd84d"
    PROFILE_UUID_WIDGET="4d0f8b36-88d3-4d22-aa7f-5d26be8ae7dd"
    ;;
  TinyBuddy)
    APP_NAME="TinyBuddy"
    XCODEPROJ_REL="TinyBuddy.xcodeproj"
    SCHEME="TinyBuddy"
    BUNDLE_ID="com.ryukeili.TinyBuddy"
    APP_GROUP="group.com.ryukeili.TinyBuddy"
    DERIVED_DATA_SUFFIX="tinybuddy-build"
    ENTITLEMENTS_APP=""  # 自动查找
    ENTITLEMENTS_WIDGET=""
    PROFILE_UUID_HOST="33d7c12d-c147-4cf6-9ea3-2a466488c509"
    PROFILE_UUID_WIDGET="b0c5bbf3-a298-4eb0-9e1e-9d8e32fe4df5"
    ;;
  CodexMonitor)
    APP_NAME="CodexMonitorNative"
    XCODEPROJ_REL=""
    SCHEME=""
    BUNDLE_ID="com.ryukeilee.CodexMonitorNativePrototype"
    APP_GROUP="group.com.ryukeilee.CodexMonitorNativePrototype"
    DERIVED_DATA_SUFFIX="codexmonitor-build"
    ENTITLEMENTS_APP="Assets/CodexMonitorNative.entitlements"
    ENTITLEMENTS_WIDGET="Assets/CodexMonitorWidgetExtension.entitlements"
    PROFILE_UUID_HOST=""
    PROFILE_UUID_WIDGET=""
    ;;
esac

# ── 路径 ──────────────────────────────────────────────────────
PROJECT_DIR="$ROOT_DIR"
[ -n "$XCODEPROJ_REL" ] && XCODEPROJ="$PROJECT_DIR/$XCODEPROJ_REL" || XCODEPROJ=""
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/$DERIVED_DATA_SUFFIX}"
BUILD_APP="$DERIVED_DATA_PATH/Build/Products/Debug/${APP_NAME}.app"
INSTALL_APP="${INSTALL_APP:-/Applications/${APP_NAME}.app}"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

# 解析 entitlements 绝对路径
[ -n "$ENTITLEMENTS_APP" ] && ENTITLEMENTS_APP="$PROJECT_DIR/$ENTITLEMENTS_APP" || ENTITLEMENTS_APP=""
[ -n "$ENTITLEMENTS_WIDGET" ] && ENTITLEMENTS_WIDGET="$PROJECT_DIR/$ENTITLEMENTS_WIDGET" || ENTITLEMENTS_WIDGET=""

# 自动查找 entitlements（TinyBuddy）
if [ "$PROJECT" = "TinyBuddy" ]; then
  for f in "$PROJECT_DIR"/*.entitlements "$PROJECT_DIR"/*/*.entitlements; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
      *Widget*|*widget*) ENTITLEMENTS_WIDGET="$f" ;;
      *) ENTITLEMENTS_APP="$f" ;;
    esac
  done
fi

# 签名证书
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(.*Apple Development.*\)".*/\1/p' | head -1 || true)"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development/{print $2; exit}' || true)"
fi

SELF_CHECK_LOG="$(mktemp "${TMPDIR:-/tmp}/${APP_NAME}-build.XXXXXX")"
BACKUP_DIR=""
cleanup() { rm -f "$SELF_CHECK_LOG" 2>/dev/null || true; [ -n "$BACKUP_DIR" ] && rm -rf "$BACKUP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

info()  { printf '\033[36m[build]\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m[build]\033[0m %s\n' "$*"; }
fail()  { printf '\033[31m[build] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. 构建 ───────────────────────────────────────────────────
info "=== Build $APP_NAME ==="

if [ "$PROJECT" = "CodexMonitor" ]; then
  info "SwiftPM build (debug)..."
  BD="$ROOT_DIR/.build"; mkdir -p "$BD/scratch" "$BD/cache"
  export CLANG_MODULE_CACHE_PATH="$BD/ModuleCache"
  swift build -c debug --scratch-path "$BD/scratch" --cache-path "$BD/cache"
  BP="$(swift build -c debug --scratch-path "$BD/scratch" --show-bin-path)"
  [ -x "$BP/$APP_NAME" ] || fail "Binary not found"

  DIST="$ROOT_DIR/dist"; BUILD_APP="$DIST/$APP_NAME.app"
  rm -rf "$BUILD_APP"; mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources"
  cp "$BP/$APP_NAME" "$BUILD_APP/Contents/MacOS/$APP_NAME"; chmod +x "$BUILD_APP/Contents/MacOS/$APP_NAME"
  cat >"$BUILD_APP/Contents/Info.plist" <<INFOPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
INFOPLIST

  WIDGET_XCODEPROJ="$ROOT_DIR/CodexMonitorWidgetExtension.xcodeproj"
  WIDGET_SCHEME="CodexMonitorWidgetExtension"
  if [ -d "$WIDGET_XCODEPROJ" ]; then
    info "Building Widget..."
    WPD="$BD/xcode-widget/Debug"
    mkdir -p "$WPD"
    xcodebuild -project "$WIDGET_XCODEPROJ" -scheme "$WIDGET_SCHEME" \
      -configuration Debug -destination "platform=macOS" \
      -derivedDataPath "$BD/xcode-widget/DerivedData" \
      CONFIGURATION_BUILD_DIR="$WPD" \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
    [ -d "$WPD/${WIDGET_SCHEME}.appex" ] || fail "Widget product not found"
    mkdir -p "$BUILD_APP/Contents/PlugIns"
    rm -rf "$BUILD_APP/Contents/PlugIns/$WIDGET_SCHEME.appex"
    ditto --norsrc --noextattr "$WPD/${WIDGET_SCHEME}.appex" "$BUILD_APP/Contents/PlugIns/$WIDGET_SCHEME.appex"
  fi
else
  info "xcodebuild (debug, no signing)..."
  xcodebuild -project "$XCODEPROJ" -scheme "$SCHEME" \
    -configuration Debug -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "platform=macOS" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
  [ -d "$BUILD_APP" ] || fail "Build product not found: $BUILD_APP"
fi
ok "Build: $BUILD_APP"

# ── 2. 签名 ───────────────────────────────────────────────────
info "=== Sign ==="
[ -n "$SIGN_IDENTITY" ] || fail "No Apple Development signing identity"

# 移除测试 bundle
if [ -d "$BUILD_APP/Contents/PlugIns/${APP_NAME}Tests.xctest" ]; then
  mv "$BUILD_APP/Contents/PlugIns/${APP_NAME}Tests.xctest" "${TMPDIR:-/tmp}/${APP_NAME}Tests.xctest.$$.bak"
fi

# 嵌入 host provisionprofile
if [ -n "${PROFILE_UUID_HOST:-}" ] && [ -f "$PROFILE_DIR/$PROFILE_UUID_HOST.provisionprofile" ]; then
  cp "$PROFILE_DIR/$PROFILE_UUID_HOST.provisionprofile" "$BUILD_APP/Contents/embedded.provisionprofile"
  info "Host provisionprofile embedded"
fi

# 签名 Widget + 嵌入 widget provisionprofile
for widget in "$BUILD_APP"/Contents/PlugIns/*.appex; do
  [ -d "$widget" ] || continue
  wname="$(basename "$widget")"

  # 嵌入 provisionprofile
  if [ -n "${PROFILE_UUID_WIDGET:-}" ] && [ -f "$PROFILE_DIR/$PROFILE_UUID_WIDGET.provisionprofile" ]; then
    mkdir -p "$widget/Contents"
    cp "$PROFILE_DIR/$PROFILE_UUID_WIDGET.provisionprofile" "$widget/Contents/embedded.provisionprofile"
  fi

  # 使用 entitlements 签名
  if [ -n "$ENTITLEMENTS_WIDGET" ] && [ -f "$ENTITLEMENTS_WIDGET" ]; then
    info "Signing widget $wname (with entitlements)..."
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
      --entitlements "$ENTITLEMENTS_WIDGET" "$widget"
  else
    info "Signing widget $wname (no entitlements file)..."
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
      --generate-entitlement-der "$widget"
  fi
done

# 签名主应用
if [ -n "$ENTITLEMENTS_APP" ] && [ -f "$ENTITLEMENTS_APP" ]; then
  info "Signing host app (with entitlements)..."
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
    --entitlements "$ENTITLEMENTS_APP" "$BUILD_APP"
else
  info "Signing host app (no entitlements file)..."
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
    --generate-entitlement-der "$BUILD_APP"
fi

codesign --verify --deep --strict --verbose=2 "$BUILD_APP" 2>&1 | tail -3
ok "Signing verified"

# ── 3. 安装 ───────────────────────────────────────────────────
info "=== Install to $INSTALL_APP ==="
OLD_PIDS="$(pgrep -x "$APP_NAME" 2>/dev/null || true)"
if [ -n "$OLD_PIDS" ]; then
  kill $OLD_PIDS 2>/dev/null || true
  for _ in $(seq 1 20); do pgrep -x "$APP_NAME" >/dev/null 2>&1 || break; sleep 0.25; done
  REMAINING="$(pgrep -x "$APP_NAME" 2>/dev/null || true)"
  [ -z "$REMAINING" ] || { kill -KILL $REMAINING 2>/dev/null || true; sleep 0.5; }
fi
if [ -d "$INSTALL_APP" ]; then
  BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-backup.XXXXXX")"
  mv "$INSTALL_APP" "$BACKUP_DIR/${APP_NAME}.app"
fi
mkdir -p "$(dirname "$INSTALL_APP")"
ditto "$BUILD_APP" "$INSTALL_APP"

# 注册 Widget
pluginkit -a "$INSTALL_APP/Contents/PlugIns/"*.appex 2>/dev/null || true
lsregister -f -R -trusted "$INSTALL_APP" 2>/dev/null || true
ok "Install: $INSTALL_APP"

# ── 4. 启动 ───────────────────────────────────────────────────
info "Launching..."
open -n "$INSTALL_APP"
for _ in $(seq 1 20); do pgrep -x "$APP_NAME" >/dev/null 2>&1 && break; sleep 0.25; done
pgrep -x "$APP_NAME" >/dev/null 2>&1 || fail "Did not launch"
ok "Running"
