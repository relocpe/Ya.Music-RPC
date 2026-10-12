# Changelog

## 1.0.0

Первый публичный релиз.

- Проект называется Ya.Music RPC (раньше собирался как YandexMusicRPC). Бандл `Ya.Music RPC.app`, исполняемый файл `YaMusicRPC`, bundle id `com.samevamp.ya-music-rpc`.
- Конфиг лежит в `~/.config/ya-music-rpc/config.json`. Прежние настройки при первом запуске подхватываются.
- Из исходников убраны чужие Discord Application ID. Теперь свой ID задаётся в `discordClientId` или переменной `YA_MUSIC_RPC_CLIENT_ID`. Без него в Discord ничего не отправляется, виджет в строке меню работает.
- Добавлены README со скриншотами, лицензия MIT, `build.sh` и `package.sh` (приложение и DMG).

Что умеет приложение: Discord Rich Presence для десктопной Яндекс Музыки (обложка, прогресс, тип «Слушает»), виджет и карточка в строке меню с управлением плеером, окно настроек, автозапуск, флаги `--diagnose` и `--verbose`.
