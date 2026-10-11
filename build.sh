#!/bin/bash
# Собирает Ya.Music RPC.app из исходников в Sources/.
# Нужен только swiftc из Command Line Tools — ни Xcode, ни brew, ни node.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="YaMusicRPC"
DISPLAY_NAME="Ya.Music RPC"
BUNDLE_ID="com.samevamp.ya-music-rpc"
VERSION="1.0.0"
BUILD_DIR="build"
APP="$BUILD_DIR/$DISPLAY_NAME.app"

echo "==> Чищу $BUILD_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Компилирую"
swiftc \
  -swift-version 5 \
  -O \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  Sources/*.swift

echo "==> Собираю бандл"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "    (нет Resources/AppIcon.icns)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- Живём только в строке меню, иконки в доке нет. -->
    <key>LSUIElement</key><true/>
    <!-- Menu-bar-only приложение без окон: macOS иначе убивает его
         через несколько секунд через Automatic Termination. -->
    <key>NSSupportsAutomaticTermination</key><false/>
    <!-- Инспектор Electron слушает http/ws на 127.0.0.1. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
PLIST

echo "APPL????" > "$APP/Contents/PkgInfo"

echo "==> Подписываю ad-hoc"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
  || echo "    (подпись не удалась — не критично)"

echo
echo "Готово: $APP"
echo "Запуск:      open \"$APP\""
echo "Диагностика: \"$APP/Contents/MacOS/$APP_NAME\" --diagnose"
