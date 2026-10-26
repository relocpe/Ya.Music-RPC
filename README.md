# Ya.Music RPC

Приложение для строки меню macOS, которое передаёт текущий трек из десктопной Яндекс Музыки в Discord Rich Presence и показывает мини-плеер.

![](docs/screenshot-1.png)

![](docs/screenshot-2.png)

Возможности:

- статус «Слушает» в Discord с обложкой и прогрессом трека;
- название трека в строке меню;
- карточка с управлением: пауза, переключение треков, лайк, перемотка;
- автозапуск при входе в систему.

## Требования

- macOS 13 или новее, Apple Silicon.
- Десктопное приложение Яндекс Музыки (проверено на версии 5.112.0).
- Discord Application ID для отображения статуса.

## Установка

1. Скачайте dmg из [релизов](https://github.com/relocpe/Ya.Music-RPC/releases/latest).
2. Перетащите `Ya.Music RPC.app` в папку «Программы».
3. Приложение подписано ad-hoc. При первом запуске откройте его через ПКМ → «Открыть» или снимите карантин:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Ya.Music RPC.app"
   ```

Значок в Dock не отображается, приложение работает только в строке меню.

## Настройка

Конфигурация хранится в `~/.config/ya-music-rpc/config.json` и частично доступна в окне настроек.

### Discord Application ID

Без него статус в Discord не отображается, строка меню продолжает работать.

1. Создайте приложение на <https://discord.com/developers/applications>. Его название будет видно в статусе, например «Яндекс Музыка».
2. Скопируйте Application ID на вкладке General Information.
3. Укажите его в `discordClientId` или в переменной окружения `YA_MUSIC_RPC_CLIENT_ID`. Переменная окружения имеет приоритет.
4. Нажмите «Переподключить» в настройках приложения.

### Параметры

| Ключ | По умолчанию | Описание |
| --- | --- | --- |
| `discordClientId` | `""` | Discord Application ID |
| `useListeningActivityType` | `true` | Тип активности «Слушает» вместо «Играет» |
| `inspectorPort` | `9229` | Порт инспектора Яндекс Музыки |
| `pollIntervalSeconds` | `1.0` | Интервал опроса, секунды |
| `showTextInMenuBar` | `true` | Показывать название трека в строке меню |
| `showCoverInMenuBar` | `true` | Показывать обложку в строке меню |
| `menuBarMaxChars` | `34` | Максимальная длина текста в строке меню |
| `menuBarMaxWidth` | `130` | Максимальная ширина текста, pt |
| `discordCoverSize` | `400` | Размер обложки для Discord, px |
| `menuCoverSize` | `600` | Размер обложки в карточке, px |
| `showSearchButton` | `false` | Кнопка поиска трека на music.yandex.ru в статусе |

## Как это работает

Приложение отправляет процессу Яндекс Музыки сигнал `SIGUSR1`, после чего Electron открывает инспектор на `127.0.0.1:9229`. Через Chrome DevTools Protocol приложение читает текущий трек и позицию воспроизведения. Статус передаётся в Discord через локальный сокет `discord-ipc-0`.

## Сборка

```bash
git clone https://github.com/relocpe/Ya.Music-RPC.git
cd Ya.Music-RPC
./build.sh            # build/Ya.Music RPC.app
./package.sh          # сборка и dmg
```

Требуется только `swiftc` из Command Line Tools, Xcode не нужен.

## Решение проблем

Запустите диагностику:

```bash
"/Applications/Ya.Music RPC.app/Contents/MacOS/YaMusicRPC" --diagnose
```

Для подробного вывода используйте `--verbose`. Лог сохраняется в `~/.config/ya-music-rpc/log.txt`.

- **«Приложение не запущено».** Откройте Яндекс Музыку.
- **Порт 9229 занят.** Его использует другой процесс Node.js с `--inspect`. Закройте его. `SIGUSR1` всегда открывает инспектор на 9229, поэтому `inspectorPort` помогает, только если Яндекс Музыка сама запущена с `--inspect=<порт>`.
- **Статус не отображается в Discord.** Проверьте, что в Discord включено «Отображать текущую активность как статус» и задан `discordClientId`.
- **Тип статуса не тот.** Он задаётся `useListeningActivityType`: `true` — «Слушает», `false` — «Играет».
- **Перестало работать после обновления Яндекс Музыки.** Возможно, в новой версии отключён инспектор.

## Лицензия

MIT, см. [LICENSE](LICENSE).

Проект неофициальный и не связан с Яндексом или Discord.
