#!/bin/bash
# 打包成 LocalTranslate.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="LocalTranslate"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

echo "==> 编译 release"
swift build -c release

echo "==> 组装 .app"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp "$ROOT/.build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"

# Info.plist
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>LocalTranslate</string>
    <key>CFBundleDisplayName</key>
    <string>LocalTranslate</string>
    <key>CFBundleIdentifier</key>
    <string>com.localtranslate.app</string>
    <key>CFBundleExecutable</key>
    <string>LocalTranslate</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.1</string>
    <key>CFBundleVersion</key>
    <string>101</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <!-- 有 Dock 图标：关掉后台代理模式。菜单栏图标照样保留。 -->
    <key>CFBundleURLTypes</key>
    <array>
      <dict>
        <key>CFBundleURLName</key>
        <string>com.localtranslate.app.url</string>
        <key>CFBundleURLSchemes</key>
        <array><string>localtranslate</string></array>
      </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
      <dict>
        <key>CFBundleTypeName</key>
        <string>Bob 插件</string>
        <key>CFBundleTypeRole</key>
        <string>Editor</string>
        <key>LSHandlerRank</key>
        <string>Owner</string>
        <key>CFBundleTypeExtensions</key>
        <array><string>bobplugin</string></array>
        <key>LSItemContentTypes</key>
        <array><string>com.localtranslate.bobplugin</string></array>
      </dict>
      <dict>
        <key>CFBundleTypeName</key>
        <string>图片</string>
        <key>CFBundleTypeRole</key>
        <string>Viewer</string>
        <key>LSHandlerRank</key>
        <string>Alternate</string>
        <key>LSItemContentTypes</key>
        <array>
          <string>public.image</string>
          <string>com.adobe.pdf</string>
        </array>
      </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
      <dict>
        <key>UTTypeIdentifier</key>
        <string>com.localtranslate.bobplugin</string>
        <key>UTTypeDescription</key>
        <string>Bob 插件</string>
        <key>UTTypeConformsTo</key>
        <array><string>public.data</string><string>public.archive</string></array>
        <key>UTTypeTagSpecification</key>
        <dict>
          <key>public.filename-extension</key>
          <array><string>bobplugin</string></array>
        </dict>
      </dict>
    </array>
    <key>NSAppTransportSecurity</key>
    <dict>
      <!-- 浏览器助手要连本机 127.0.0.1 的辅助服务；Magpie 网关同理 -->
      <key>NSAllowsLocalNetworking</key><true/>
    </dict>
    <key>LSUIElement</key>
    <false/>
    <key>NSAppleScriptEnabled</key>
    <true/>
    <key>OSAScriptingDefinition</key>
    <string>LocalTranslate.sdef</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>LocalTranslate 需要发送快捷键事件来读取你选中的文字。</string>
</dict>
</plist>
PLIST

# 复制 sdef 脚本定义
if [ -f "$ROOT/Resources/LocalTranslate.sdef" ]; then
    cp "$ROOT/Resources/LocalTranslate.sdef" "$RES_DIR/LocalTranslate.sdef"
fi

# 图标：脚本生成
echo "==> 生成图标"
python3 "$ROOT/scripts/make_icon.py" "$RES_DIR/AppIcon.icns"

# 签名：优先用固定身份的自签名证书（重编译不掉辅助功能授权），再退到 ad-hoc。
#
# 两个坑，都踩过：
# 1. 签名钥匙串被系统锁过一次再解锁，私钥的 partition list 失效，
#    codesign 报 errSecInternalComponent。所以每次签之前重设一遍。
# 2. 按名字签可能撞上同名证书（报 ambiguous）。所以按指纹签。
# 退回 ad-hoc 时必须大声警告——ad-hoc 身份每次重编译都变，用户会发现
# 辅助功能授权莫名没了，这种问题最难查。
echo "==> 签名"
SIGN_KC="$HOME/Library/Keychains/LocalTranslate.keychain-db"
FINGERPRINT=""
[ -f "$ROOT/.signing/cert-sha1.txt" ] && FINGERPRINT="$(cat "$ROOT/.signing/cert-sha1.txt" | tr -d '[:space:]')"
SIGNED_OK=0
if [ -f "$SIGN_KC" ]; then
    security unlock-keychain -p "" "$SIGN_KC" >/dev/null 2>&1 || true
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$SIGN_KC" >/dev/null 2>&1 || true
fi
if [ -n "$FINGERPRINT" ]; then
    if codesign --force --deep --sign "$FINGERPRINT" "$APP_DIR" >/dev/null 2>&1; then
        echo "  已用证书 $FINGERPRINT 签名（身份稳定）"
        SIGNED_OK=1
    else
        echo "  !! 用证书签名失败，退回 ad-hoc"
    fi
else
    echo "  · 没有 .signing/cert-sha1.txt，先跑 ./scripts/setup_signing.sh 才能用固定身份"
fi
if [ "$SIGNED_OK" -eq 0 ]; then
    echo "  !! 本次是 ad-hoc 签名：重编译后辅助功能授权会掉，需要重新勾选"
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || echo "  !! ad-hoc 签名也失败"
fi
codesign -d -r- "$APP_DIR" 2>/dev/null | grep designated | sed 's/^/  /'
if [ "$SIGNED_OK" -eq 1 ]; then
    codesign -d -r- "$APP_DIR" 2>/dev/null | grep -q "certificate leaf" \
        || { echo "  !! 自称用证书签了，但 designated requirement 里没有 certificate leaf"; exit 1; }
fi

echo "==> 完成: $APP_DIR"
echo
echo "安装到 /Applications:"
echo "  cp -R \"$APP_DIR\" /Applications/"
