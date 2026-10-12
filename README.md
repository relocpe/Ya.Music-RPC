# Ya.Music RPC

[![build](https://github.com/samevamp/Ya.Music-RPC/actions/workflows/build.yml/badge.svg)](https://github.com/samevamp/Ya.Music-RPC/actions/workflows/build.yml)

Приложение для меню-бара: показывает в Discord, что играет в десктопной Яндекс Музыке, и даёт мини-плеер прямо в строке меню.

Сделал для себя, нормального варианта под мак не нашёл. Выложил, вдруг пригодится.

![](docs/screenshot-1.png)

Что умеет: статус «Слушает» в Discord с обложкой и прогрессом, виджет в меню-баре, карточка с управлением (пауза, треки, лайк, перемотка), автозапуск. Диагностика через `--diagnose` и `--verbose`.

![](docs/screenshot-2.png)

## Как работает

Приложение шлёт Яндекс Музыке `SIGUSR1`, у неё открывается инспектор на `127.0.0.1:9229`, оттуда через DevTools Protocol читается трек и время. В Discord всё уходит через локальный сокет `discord-ipc-0`.

## Установка

Скачай dmg из [релизов](https://github.com/samevamp/Ya.Music-RPC/releases/latest), перетащи в Applications. Подпись ad-hoc, поэтому на первом запуске ПКМ → Открыть, или:

```bash
xattr -dr com.apple.quarantine "/Applications/Ya.Music RPC.app"
```

Нужен macOS 13+ и Apple Silicon. Иконка появится только в меню-баре, Яндекс Музыка должна быть запущена.

## Свой Discord ID

Без него Discord ничего не покажет, а виджет в меню-баре будет работать.

1. На https://discord.com/developers/applications создай приложение. Его название увидят друзья в статусе, например «Яндекс Музыка».
2. Скопируй Application ID со вкладки General Information.
3. Впиши в `discordClientId` в `~/.config/ya-music-rpc/config.json` или задай переменную `YA_MUSIC_RPC_CLIENT_ID` (она главнее).
4. Нажми «Переподключить» в настройках приложения.

Остальные параметры (ширина текста, обложка, `inspectorPort`, `useListeningActivityType` и т.д.) есть в том же конфиге и в окне настроек.

## Сборка

```bash
git clone https://github.com/samevamp/Ya.Music-RPC.git && cd Ya.Music-RPC
./build.sh && open "build/Ya.Music RPC.app"
./package.sh   # то же + dmg
```

Хватит `swiftc` из Command Line Tools, Xcode не нужен.

## Если не работает

Сначала запусти и смотри вывод (лог лежит в `~/.config/ya-music-rpc/log.txt`):

```bash
"/Applications/Ya.Music RPC.app/Contents/MacOS/YaMusicRPC" --diagnose
```

- «приложение не запущено»: открой Яндекс Музыку.
- порт 9229 занят: там висит чужой node с `--inspect`, закрой его или поменяй `inspectorPort`.
- в Discord пусто: проверь, что в нём включено «Отображать текущую активность как статус» и задан `discordClientId`.
- пишет «Играет» вместо «Слушает»: поставь `useListeningActivityType: false`.
- сломалось после обновления Яндекс Музыки: возможно, они закрыли инспектор. Работало на 5.112.0.

Неофициальный проект, с Яндексом и Discord не связан. Лицензия [MIT](LICENSE).

---

Unofficial macOS menu-bar app: Discord Rich Presence + mini player for the Yandex Music desktop app. Build with `./build.sh`, needs macOS 13+ and arm64.
