#!/bin/bash
# Собирает приложение и упаковывает его в build/Ya.Music-RPC.dmg.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Ya.Music RPC"
VOLUME_NAME="Ya.Music RPC"
APP="build/$APP_NAME.app"
DMG="build/Ya.Music-RPC.dmg"

./build.sh

echo
echo "==> Готовлю содержимое образа"
STAGING="build/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Короткая памятка рядом с приложением — на случай предупреждения Gatekeeper.
cat > "$STAGING/ПРОЧТИ МЕНЯ.txt" <<'TXT'
Ya.Music RPC
============

Установка:
  Перетащи Ya.Music RPC в папку Applications рядом.

Первый запуск:
  Приложение подписано ad-hoc (без платного сертификата Apple), поэтому
  macOS может сказать «не удаётся проверить разработчика».
  Тогда: правый клик по приложению -> «Открыть» -> «Открыть».
  Это нужно ровно один раз.

Дальше всё само:
  - иконка появляется в строке меню (в доке её нет)
  - для статуса в Discord нужен Discord Application ID (см. README:
    discordClientId в ~/.config/ya-music-rpc/config.json), без него
    работает только строка меню
  - Яндекс Музыка должна быть запущена

Автозапуск включается галочкой «Запускать при входе» в меню приложения.

Если что-то не так, открой Терминал и выполни:
  "/Applications/Ya.Music RPC.app/Contents/MacOS/YaMusicRPC" --diagnose
TXT

echo "==> Собираю DMG"
rm -f "$DMG"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGING"

SIZE=$(du -h "$DMG" | cut -f1 | tr -d ' ')
echo
echo "Готово: $DMG ($SIZE)"
echo "Проверить: open $DMG"
