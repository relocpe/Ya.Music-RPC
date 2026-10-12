import AppKit

@main
@MainActor
enum EntryPoint {
    private static var delegate: AppDelegate?

    static func main() {
        // SIGPIPE: запись в закрытый сокет не должна убивать процесс
        _ = signal(SIGPIPE, SIG_IGN)

        if CommandLine.arguments.contains("--verbose") {
            Log.verbose = true
        }
        if CommandLine.arguments.contains("--diagnose") {
            Diagnostics.runAndExit()
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.accessory) // только строка меню, без иконки в доке
        // без окон macOS убивает такое приложение через пару секунд (automatic termination)
        application.disableRelaunchOnLogin()
        ProcessInfo.processInfo.disableAutomaticTermination("menu-bar RPC")
        ProcessInfo.processInfo.disableSuddenTermination()
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config.load()
    private var source: YandexMusicSource!
    private let discord = DiscordRPC()
    private var menuBar: MenuBarController!
    private var loop: Task<Void, Never>?
    private var configStamp: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Ya.Music RPC запущен")
        LaunchAtLogin.migrateLegacy()
        if config.effectiveClientId.isEmpty {
            Log.warn("Discord Application ID не задан (config.json: discordClientId или переменная YA_MUSIC_RPC_CLIENT_ID): присутствие в Discord не будет работать. Заведи свой ID — см. README")
        }
        source = YandexMusicSource(config: config)
        configStamp = configModificationDate()

        menuBar = MenuBarController(config: config)
        menuBar.onReconnect = { [weak self] in
            guard let self else { return }
            self.discord.reconnectSoon()
            Task { await self.tick() }
        }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.onMenuWillOpen = { [weak self] in
            guard let self else { return }
            Task { await self.tick() }
        }
        menuBar.onPlayerCommand = { [weak self] command in
            guard let self else { return }
            Task {
                await self.source.send(command)
                try? await Task.sleep(nanoseconds: 250_000_000)
                await self.tick()
            }
        }

        discord.apply(config: config)

        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let interval = max(self.config.pollIntervalSeconds, 0.25)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        loop?.cancel()
        discord.shutdown()
        Log.info("Ya.Music RPC остановлен")
    }

    private func tick() async {
        reloadConfigIfNeeded()
        let track = await source.poll()
        let status = await source.status
        discord.update(with: track)
        menuBar.update(track: track, source: status, discord: discord.status)
    }

    private func reloadConfigIfNeeded() {
        let stamp = configModificationDate()
        guard stamp != configStamp else { return }
        configStamp = stamp
        config = Config.load()
        Log.info("настройки перечитаны")
        menuBar.apply(config: config)
        discord.apply(config: config)
        let updated = config
        Task { await source.apply(config: updated) }
    }

    private func configModificationDate() -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: Config.fileURL.path)[.modificationDate] as? Date
    }
}

/// --diagnose: печатает, что видит приложение
enum Diagnostics {
    static func runAndExit() -> Never {
        Log.verbose = true
        let config = Config.load()
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            let source = YandexMusicSource(config: config)
            print("Расположение:      \(Bundle.main.bundleURL.path)")
            let autostart = LaunchAtLogin.blockedReason.map { "недоступен — \($0)" }
                ?? (LaunchAtLogin.isEnabled ? "включён" : "выключен")
            print("Автозапуск:        \(autostart)")
            print("Конфиг:            \(Config.fileURL.path)")
            if config.effectiveClientId.isEmpty {
                print("Discord client id: НЕ ЗАДАН (config.json: discordClientId или \(Config.clientIdEnvKey)), см. README")
            } else {
                print("Discord client id: \(Config.maskedClientId(config.effectiveClientId)) (свой, из конфига или \(Config.clientIdEnvKey))")
            }

            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "ru.yandex.desktop.music")
            print("Яндекс Музыка:     \(running.first.map { "pid \($0.processIdentifier)" } ?? "не запущена")")

            let track = await source.poll()
            print("Статус источника:  \(await source.status.description)")
            print("Поиск <audio>:     \(await source.diagnostics)")

            if let track {
                let position = track.position.map { TrackState.formatTime($0) } ?? "—"
                let duration = track.duration.map { TrackState.formatTime($0) } ?? "—"
                print("""
                Трек:              \(track.title)
                Исполнитель:       \(track.artist)
                Альбом:            \(track.album)
                Играет:            \(track.isPlaying ? "да" : "нет")
                Позиция:           \(position) / \(duration)
                Обложка:           \(track.coverURL(size: config.menuCoverSize)?.absoluteString ?? "—")
                """)
            } else {
                print("Трек:              не прочитан")
            }

            let socket = (0..<10)
                .map { (NSTemporaryDirectory() as NSString).appendingPathComponent("discord-ipc-\($0)") }
                .first { FileManager.default.fileExists(atPath: $0) }
            print("Сокет Discord:     \(socket ?? "не найден (Discord не запущен?)")")

            let paused = track.map { current -> TrackState in
                var copy = current
                copy.isPlaying = false
                return copy
            }
            let cases: [(String, TrackState?)] = [("текущий трек", track), ("на паузе", paused)]
            for (label, sample) in cases {
                guard let sample else { continue }
                let payload = DiscordRPC.activityPayload(
                    for: sample,
                    useListeningType: config.useListeningActivityType,
                    showSearchButton: config.showSearchButton,
                    coverSize: config.discordCoverSize
                )
                let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
                    .map { String(decoding: $0, as: UTF8.self) } ?? "—"
                print("\nПрисутствие — \(label):\n\(json)")
            }

            semaphore.signal()
        }

        semaphore.wait()
        exit(0)
    }
}
