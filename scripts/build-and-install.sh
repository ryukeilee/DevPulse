#!/usr/bin/env bash
# build-and-install.sh — 构建 + 手动签名（嵌入 provisionprofile）+ 安装 + 启动
#
# 自动适配 DevPulse / TinyBuddy / Codex Monitor Native Prototype 三个项目。
# 使用本地已缓存的 provisioning profiles 手动嵌入并签名，
# 确保 Widget extension 被正确签名和注册，Widget 正常显示。
#
# 用法:
#   ./script/build-and-install.sh                    # 构建签名安装并启动
#   PROJECT=DevPulse ./script/build-and-install.sh   # 强制指定项目

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_NAME="$(basename "$ROOT_DIR")"

PROJECT="${PROJECT:-}"
if [ -z "$PROJECT" ]; then
  case "$REPO_NAME" in
    DevPulse)                         PROJECT="DevPulse" ;;
    TinyBuddy)                        PROJECT="TinyBuddy" ;;
    "Codex Monitor Native Prototype") PROJECT="CodexMonitor" ;;
    *)
      echo "ERROR: Cannot detect project. Set PROJECT=DevPulse|TinyBuddy|CodexMonitor" >&2
      exit 1 ;;
  esac
fi

# ── 项目配置 ──────────────────────────────────────────────────
case "$PROJECT" in
  DevPulse)
    APP_NAME="DevPulse"
    XCODEPROJ_REL="DevPulseNative/DevPulseNative.xcodeproj"
    SCHEME="DevPulse"
    BUNDLE_ID="local.devpulse.app"
    APP_GROUP="group.local.devpulse"
    DERIVED_DATA_SUFFIX="devpulse-build"
    # 已知的 provisioning profile UUID（从本地 keychain 读取）
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
    PROFILE_UUID_HOST="33d7c12d-c147-4cf6-9ea3-2a466488c509"
    PROFILE_UUID_WIDGET="b0c5bbf3-a298-4eb0-9e1e-9d8e32fe4df5"
    ;;
  CodexMonitor)
    APP_NAME="CodexMonitorNative"
    XCODEPROJ_REL=""  # SwiftPM
    SCHEME=""
    BUNDLE_ID="com.ryukeilee.CodexMonitorNativePrototype"
    APP_GROUP="group.com.ryukeilee.CodexMonitorNativePrototype"
    DERIVED_DATA_SUFFIX="codexmonitor-build"
    PROFILE_UUID_HOST=""
    PROFILE_UUID_WIDGET=""
    ;;
  *)
    echo "ERROR: Unknown project '$PROJECT'" >&2
    exit 1 ;;
esac

# ── 路径 ──────────────────────────────────────────────────────
PROJECT_DIR="$ROOT_DIR"
[ -n "$XCODEPROJ_REL" ] && XCODEPROJ="$PROJECT_DIR/$XCODEPROJ_REL" || XCODEPROJ=""
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/$DERIVED_DATA_SUFFIX}"
BUILD_APP="$DERIVED_DATA_PATH/Build/Products/Debug/${APP_NAME}.app"
INSTALL_APP="${INSTALL_APP:-/Applications/${APP_NAME}.app}"

# 签名证书（自动查找 Apple Development 证书）
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(.*Apple Development.*\)".*/\1/p' | head -1 || true)"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development/{print $2; exit}' || true)"
fi

PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
SELF_CHECK_LOG="$(mktemp "${TMPDIR:-/tmp}/${APP_NAME}-build.XXXXXX")"
BACKUP_DIR=""

cleanup() {
  rm -f "$SELF_CHECK_LOG" 2>/dev/null || true
  [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] && rm -rf "$BACKUP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

info()  { printf '\033[36m[build]\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m[build]\033[0m %s\n' "$*"; }
fail()  { printf '\033[31m[build] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. 构建 ───────────────────────────────────────────────────
info "=== Build $APP_NAME ($PROJECT) ==="

if [ "$PROJECT" = "CodexMonitor" ]; then
  # ── CodexMonitor: SwiftPM ────────────────────────────────
  info "SwiftPM build (debug)..."
  BUILD_DIR="$ROOT_DIR/.build"
  export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
  swift build -c debug \
    --scratch-path "$BUILD_DIR/scratch" \
    --cache-path "$BUILD_DIR/cache" \
    --config-path "$BUILD_DIR/config" \
    --security-path "$BUILD_DIR/security"
  BIN_PATH="$(swift build -c debug --scratch-path "$BUILD_DIR/scratch" --show-bin-path)"
  BINARY="$BIN_PATH/$APP_NAME"
  [ -x "$BINARY" ] || fail "Binary not found: $BINARY"

  DIST_DIR="$ROOT_DIR/dist"
  BUILD_APP="$DIST_DIR/$APP_NAME.app"
  rm -rf "$BUILD_APP"
  mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources"
  cp "$BINARY" "$BUILD_APP/Contents/MacOS/$APP_NAME"
  chmod +x "$BUILD_APP/Contents/MacOS/$APP_NAME"

  cat >"$BUILD_APP/Contents/Info.plist" <<PLIST
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
PLIST

  WIDGET_XCODEPROJ="$ROOT_DIR/CodexMonitorWidgetExtension.xcodeproj"
  WIDGET_SCHEME="CodexMonitorWidgetExtension"
  if [ -d "$WIDGET_XCODEPROJ" ]; then
    info "Building Widget..."
    WIDGET_BUILD_DIR="$BUILD_DIR/xcode-widget"
    WIDGET_PRODUCTS_DIR="$WIDGET_BUILD_DIR/Debug"
    xcodebuild -project "$WIDGET_XCODEPROJ" -scheme "$WIDGET_SCHEME" \
      -configuration Debug -destination "platform=macOS" \
      -derivedDataPath "$WIDGET_BUILD_DIR/DerivedData" \
      CONFIGURATION_BUILD_DIR="$WIDGET_PRODUCTS_DIR" \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
    WIDGET_BUNDLE="$WIDGET_PRODUCTS_DIR/${WIDGET_SCHEME}.appex"
    [ -d "$WIDGET_BUNDLE" ] || fail "Widget product not found: $WIDGET_BUNDLE"
    mkdir -p "$BUILD_APP/Contents/PlugIns"
    rm -rf "$BUILD_APP/Contents/PlugIns/$WIDGET_SCHEME.appex"
    ditto --norsrc --noextattr "$WIDGET_BUNDLE" "$BUILD_APP/Contents/PlugIns/$WIDGET_SCHEME.appex"
  fi
else
  # ── DevPulse / TinyBuddy: xcodebuild 无签名 ──────────────
  info "xcodebuild (debug, no signing)..."
  xcodebuild -project "$XCODEPROJ" -scheme "$SCHEME" \
    -configuration Debug -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "platform=macOS" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

  [ -d "$BUILD_APP" ] || fail "Build product not found: $BUILD_APP"
fi

ok "Build success: $BUILD_APP"

# ── 2. 嵌入 Provisioning Profiles + 签名 ─────────────────────
info "=== Sign $APP_NAME ==="
[ -n "$SIGN_IDENTITY" ] || fail "No Apple Development signing identity found in keychain."

# 移除测试 bundle（如果存在）
if [ -d "$BUILD_APP/Contents/PlugIns/${APP_NAME}Tests.xctest" ]; then
  info "Removing test bundle..."
  mv "$BUILD_APP/Contents/PlugIns/${APP_NAME}Tests.xctest" "${TMPDIR:-/tmp}/${APP_NAME}Tests.xctest.$$.bak"
fi

# 嵌入 host provisionprofile
if [ -n "${PROFILE_UUID_HOST:-}" ]; then
  HOST_PROFILE="$PROFILE_DIR/$PROFILE_UUID_HOST.provisionprofile"
  if [ -f "$HOST_PROFILE" ]; then
    info "Embedding host provisionprofile: $PROFILE_UUID_HOST"
    cp "$HOST_PROFILE" "$BUILD_APP/Contents/embedded.provisionprofile"
  else
    info "Warning: Host provisionprofile not found at $HOST_PROFILE"
  fi
fi

# 签名 Widget（如果有）
WIDGET_EXTS=()
for widget in "$BUILD_APP"/Contents/PlugIns/*.appex; do
  [ -d "$widget" ] || continue
  WIDGET_EXTS+=("$widget")
  wname="$(basename "$widget")"

  # 嵌入 widget provisionprofile
  if [ -n "${PROFILE_UUID_WIDGET:-}" ]; then
    WIDGET_PROFILE="$PROFILE_DIR/$PROFILE_UUID_WIDGET.provisionprofile"
    if [ -f "$WIDGET_PROFILE" ]; then
      mkdir -p "$widget/Contents"
      cp "$WIDGET_PROFILE" "$widget/Contents/embedded.provisionprofile"
      info "Embedded widget provisionprofile for $wname"
    fi
  fi

  info "Signing widget: $wname"
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
    --generate-entitlement-der "$widget"
done

# 签名主应用
info "Signing host app..."
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
  --generate-entitlement-der "$BUILD_APP"

# 验证
codesign --verify --deep --strict --verbose=2 "$BUILD_APP" 2>&1 | tail -3
ok "Code signing verified"

# ── 3. 安装 ───────────────────────────────────────────────────
info "=== Install to $INSTALL_APP ==="

OLD_PIDS="$(pgrep -x "$APP_NAME" 2>/dev/null || true)"
if [ -n "$OLD_PIDS" ]; then
  info "Stopping running $APP_NAME..."
  kill $OLD_PIDS 2>/dev/null || true
  for _ in $(seq 1 20); do pgrep -x "$APP_NAME" >/dev/null 2>&1 || break; sleep 0.25; done
  REMAINING="$(pgrep -x "$APP_NAME" 2>/dev/null || true)"
  [ -z "$REMAINING" ] || { kill -KILL $REMAINING 2>/dev/null || true; sleep 0.5; }
fi

if [ -d "$INSTALL_APP" ]; then
  BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-backup.XXXXXX")"
  mv "$INSTALL_APP" "$BACKUP_DIR/${APP_NAME}.app"
  info "Backed up to $BACKUP_DIR"
fi

mkdir -p "$(dirname "$INSTALL_APP")"
ditto "$BUILD_APP" "$INSTALL_APP"

# 注册 LaunchServices
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
  -f -R -trusted "$INSTALL_APP" 2>/dev/null || true

ok "Install success: $INSTALL_APP"

# ── 4. 启动 ───────────────────────────────────────────────────
info "Launching $APP_NAME..."
open -n "$INSTALL_APP"
for _ in $(seq 1 20); do
  pgrep -x "$APP_NAME" >/dev/null 2>&1 && break
  sleep 0.25
done
pgrep -x "$APP_NAME" >/dev/null 2>&1 || fail "$APP_NAME did not launch."
ok "Running: $INSTALL_APP"
