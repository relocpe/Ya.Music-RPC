#!/bin/bash
# Пересобирает Resources/AppIcon.icns. Запускать вручную — только если меняешь иконку.
set -euo pipefail

cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Компилирую генератор"
swiftc -swift-version 5 -O -parse-as-library -framework AppKit -o "$WORK/make-icon" tools/make-icon.swift

echo "==> Рисую"
"$WORK/make-icon" "$WORK"

echo "==> Собираю iconset"
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
cp "$WORK/icon_16.png"   "$SET/icon_16x16.png"
cp "$WORK/icon_32.png"   "$SET/icon_16x16@2x.png"
cp "$WORK/icon_32.png"   "$SET/icon_32x32.png"
cp "$WORK/icon_64.png"   "$SET/icon_32x32@2x.png"
cp "$WORK/icon_128.png"  "$SET/icon_128x128.png"
cp "$WORK/icon_256.png"  "$SET/icon_128x128@2x.png"
cp "$WORK/icon_256.png"  "$SET/icon_256x256.png"
cp "$WORK/icon_512.png"  "$SET/icon_256x256@2x.png"
cp "$WORK/icon_512.png"  "$SET/icon_512x512.png"
cp "$WORK/icon_1024.png" "$SET/icon_512x512@2x.png"

mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns

echo "Готово: Resources/AppIcon.icns"
