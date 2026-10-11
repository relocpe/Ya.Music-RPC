import Foundation

/// Автозапуск через LaunchAgent. Плист лежит в ~/Library/LaunchAgents и
/// подхватывается системой при входе в учётку.
enum LaunchAtLogin {
    static let label = "com.samevamp.ya-music-rpc"
    static let legacyLabel = "com.samevamp.yandex-music-rpc"

    private static var legacyPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    }

    /// Старый LaunchAgent (до переименования): выгружаем и удаляем, а если автозапуск
    /// был включён — включаем новый, чтобы не получилось два запуска при входе.
    static func migrateLegacy() {
        guard FileManager.default.fileExists(atPath: legacyPlistURL.path) else { return }
        launchctl(["bootout", "gui/\(getuid())/\(legacyLabel)"])
        try? FileManager.default.removeItem(at: legacyPlistURL)
        Log.info("старый автозапуск \(legacyLabel) удалён")
        if !isEnabled { enable() }
    }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Из смонтированного образа автозапуск включать бессмысленно: после извлечения
    /// путь в LaunchAgent перестанет существовать.
    static var blockedReason: String? {
        guard let path = Bundle.main.bundleURL.standardized.path as String? else { return nil }
        if path.hasPrefix("/Volumes/") {
            return "сначала перетащи приложение в Applications"
        }
        return nil
    }

    static func set(enabled: Bool) {
        enabled ? enable() : disable()
    }

    private static func enable() {
        if let reason = blockedReason {
            Log.warn("автозапуск не включён: \(reason)")
            return
        }
        guard let executable = Bundle.main.executableURL?.path else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
            Log.info("автозапуск включён: \(plistURL.path)")
        } catch {
            Log.warn("не смог включить автозапуск: \(error.localizedDescription)")
        }
    }

    private static func disable() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        Log.info("автозапуск выключен")
    }

    /// launchctl может ругаться, если сервис уже загружен или уже выгружен —
    /// для нас это не ошибка, файл всё равно определяет поведение при входе.
    private static func launchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
