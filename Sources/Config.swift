import Foundation

// ~/.config/ya-music-rpc/config.json, читается при каждом обращении
struct Config: Codable, Equatable {
    /// https://discord.com/developers/applications; env YA_MUSIC_RPC_CLIENT_ID важнее, пусто — rpc выключен
    var discordClientId: String = ""

    var menuBarMaxChars: Int = 34

    var showCoverInMenuBar: Bool = true

    var showTextInMenuBar: Bool = true

    var menuBarText: String? = nil

    /// pt, по умолчанию 130
    var menuBarMaxWidth: Double? = nil

    var pollIntervalSeconds: Double = 1.0

    /// у node по умолчанию 9229
    var inspectorPort: Int = 9229

    var discordCoverSize: Int = 400

    var menuCoverSize: Int = 600

    var useListeningActivityType: Bool = true

    // выключено: ссылка ведёт на music.yandex.ru и выдаёт источник
    var showSearchButton: Bool = false

    static let clientIdEnvKey = "YA_MUSIC_RPC_CLIENT_ID"

    // env > config.json > пусто
    var effectiveClientId: String {
        let env = ProcessInfo.processInfo.environment[Config.clientIdEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !env.isEmpty { return env }
        return discordClientId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // для логов: 4 первых и 2 последних символа
    static func maskedClientId(_ id: String) -> String {
        guard id.count > 6 else { return String(repeating: "•", count: id.count) }
        return "\(id.prefix(4))…\(id.suffix(2))"
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ya-music-rpc", isDirectory: true)
    }

    static var legacyDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/yandex-music-rpc", isDirectory: true)
    }

    // переносим из старой папки, саму её не трогаем
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
            // лог может быть не готов
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
