import Foundation

/// Настройки лежат в ~/.config/ya-music-rpc/config.json и перечитываются
/// при каждом обращении к меню, чтобы правки подхватывались без пересборки.
struct Config: Codable, Equatable {
    /// Application ID из https://discord.com/developers/applications.
    /// Можно задать также переменной окружения YA_MUSIC_RPC_CLIENT_ID (она важнее).
    /// Пусто — присутствие в Discord не включится (в логе будет предупреждение).
    var discordClientId: String = ""

    /// Максимальная длина текста в меню-баре (символы, вместе с многоточием).
    var menuBarMaxChars: Int = 34

    /// Показывать ли миниатюру обложки слева от текста в меню-баре.
    var showCoverInMenuBar: Bool = true

    /// Показывать ли текст рядом с обложкой (false — только обложка).
    var showTextInMenuBar: Bool = true

    /// Что писать в строке меню: "artist" или "title". Пусто — исполнитель.
    var menuBarText: String? = nil

    /// Максимальная ширина текста в строке меню, pt. Пусто — 130.
    var menuBarMaxWidth: Double? = nil

    /// Как часто опрашивать плеер, секунды.
    var pollIntervalSeconds: Double = 1.0

    /// Порт Node-инспектора Яндекс Музыки. Node по умолчанию слушает 9229.
    var inspectorPort: Int = 9229

    /// Размер обложки, которую отдаём Discord (в URL avatars.yandex.net).
    var discordCoverSize: Int = 400

    /// Размер обложки для окна меню.
    var menuCoverSize: Int = 600

    /// Слать ли в Discord тип активности «Слушает» вместо «Играет».
    var useListeningActivityType: Bool = true

    /// Кнопка под присутствием со ссылкой на поиск трека.
    /// По умолчанию выключена: ссылка ведёт на music.yandex.ru, а это выдаёт источник.
    var showSearchButton: Bool = false

    static let clientIdEnvKey = "YA_MUSIC_RPC_CLIENT_ID"

    /// ID с учётом переменной окружения: env > config.json > пусто.
    var effectiveClientId: String {
        let env = ProcessInfo.processInfo.environment[Config.clientIdEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !env.isEmpty { return env }
        return discordClientId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ya-music-rpc", isDirectory: true)
    }

    /// Старая папка настроек (до переименования в Ya.Music RPC).
    static var legacyDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/yandex-music-rpc", isDirectory: true)
    }

    /// Переносит config.json и log.txt из старой папки, если новой ещё нет.
    /// Старую папку не трогаем — это резервная копия.
    static func migrateLegacyIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: directory.path),
              fm.fileExists(atPath: legacyDirectory.path) else { return }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["config.json", "log.txt"] {
                let src = legacyDirectory.appendingPathComponent(name)
                if fm.fileExists(atPath: src.path) {
                    try fm.copyItem(at: src, to: directory.appendingPathComponent(name))
                }
            }
        } catch {
            // Лог ещё может быть не готов — пишем в stderr.
            FileHandle.standardError.write(Data("миграция настроек не удалась: \(error.localizedDescription)\n".utf8))
        }
    }

    static var fileURL: URL {
        directory.appendingPathComponent("config.json")
    }

    static func load() -> Config {
        migrateLegacyIfNeeded()
        guard let data = try? Data(contentsOf: fileURL) else {
            let fresh = Config()
            fresh.saveQuietly()
            return fresh
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            Log.warn("config.json не разобрался (\(error.localizedDescription)), беру значения по умолчанию")
            return Config()
        }
    }

    func saveQuietly() {
        do {
            try FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: Config.fileURL, options: .atomic)
        } catch {
            Log.warn("не смог записать config.json: \(error.localizedDescription)")
        }
    }
}
