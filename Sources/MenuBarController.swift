import AppKit

/// Иконка в строке меню: обложка + исполнитель, а по клику — карточка трека.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let nowPlayingView = NowPlayingView()
    private let covers = CoverLoader()

    private let reconnectItem = NSMenuItem(title: "Discord не подключён — переподключиться", action: #selector(reconnect), keyEquivalent: "r")
    private let reconnectSeparator = NSMenuItem.separator()
    private let settings = SettingsWindowController()

    private var config: Config
    private var track: TrackState?
    private var sourceStatus: SourceStatus = .notRunning
    private var discordStatus: DiscordRPC.Status = .disconnected("подключаюсь…")
    private var lastMenuCoverKey: String?
    private var lastStatusCoverKey: String?
    private var lastStatusPlaying: Bool?

    var onMenuWillOpen: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onQuit: (() -> Void)?
    var onPlayerCommand: ((PlayerCommand) -> Void)?

    init(config: Config) {
        self.config = config
        super.init()
        buildMenu()
        statusItem.menu = menu
        nowPlayingView.onCommand = { [weak self] command in
            self?.onPlayerCommand?(command)
        }
        nowPlayingView.onCopyLink = { [weak self] in
            self?.copyTrack()
        }
        settings.onReconnect = { [weak self] in
            self?.onReconnect?()
        }
        nowPlayingView.onOpenPlayer = { [weak self] in
            self?.menu.cancelTracking()
            self?.openYandexMusic()
        }
        applyToButton()
        Log.info("иконка в строке меню: кнопка=\(statusItem.button != nil), видима=\(statusItem.isVisible), окно=\(statusItem.button?.window.map { "\($0.frame)" } ?? "нет")")
    }

    func apply(config: Config) {
        self.config = config
        lastStatusCoverKey = nil
        lastStatusPlaying = nil
        applyToButton()
        settings.reanchor()
    }

    // MARK: - Обновление

    func update(track: TrackState?, source: SourceStatus, discord: DiscordRPC.Status) {
        self.track = track
        self.sourceStatus = source
        self.discordStatus = discord
        applyToButton()
        updateReconnectItem()
        if menu.highlightedItem != nil || nowPlayingView.window != nil {
            refreshMenuContents()
        }
    }

    private func applyToButton() {
        guard let button = statusItem.button else { return }

        let text = menuBarText(font: button.font ?? .menuBarFont(ofSize: 0))
        button.title = text
        if let track, !track.isEmpty {
            button.toolTip = [track.artist, track.title].filter { !$0.isEmpty }.joined(separator: " — ")
        } else {
            button.toolTip = nil
        }
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
        Log.debug("строка меню: «\(text)», ширина \(Int(button.frame.width))")

        guard config.showCoverInMenuBar,
              let track,
              let url = track.coverURL(size: 100)
        else {
            setFallbackIcon(on: button)
            return
        }

        let key = url.absoluteString
        if let image = covers.image(for: url, then: { [weak self] image in
            guard let self, self.track?.coverURL(size: 100)?.absoluteString == key else { return }
            self.statusItem.button?.image = image.roundedThumbnail(side: 18, cornerRadius: 4, alpha: self.track?.isPlaying == false ? 0.55 : 1)
            self.lastStatusCoverKey = key
            self.lastStatusPlaying = self.track?.isPlaying
        }) {
            if lastStatusCoverKey != key || button.image == nil || lastStatusPlaying != track.isPlaying {
                button.image = image.roundedThumbnail(side: 18, cornerRadius: 4, alpha: track.isPlaying ? 1 : 0.55)
                lastStatusCoverKey = key
                lastStatusPlaying = track.isPlaying
            }
        } else if lastStatusCoverKey != key {
            setFallbackIcon(on: button)
        }
    }

    private func setFallbackIcon(on button: NSStatusBarButton) {
        let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Яндекс Музыка")
        symbol?.isTemplate = true
        button.image = symbol
        lastStatusCoverKey = nil
        lastStatusPlaying = nil
    }

    private func menuBarText(font: NSFont) -> String {
        guard config.showTextInMenuBar, let track, !track.isEmpty else { return "" }
        let wantsTitle = config.menuBarText == "title"
        var text: String
        if wantsTitle {
            text = track.title.isEmpty ? track.artist : track.title
        } else {
            text = track.artist.isEmpty ? track.title : track.artist
        }

        let limit = max(config.menuBarMaxChars, 8)
        if text.count > limit {
            text = String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        // Режем по ширине, чтобы длинное имя не выталкивало соседние значки.
        let maxWidth = CGFloat(config.menuBarMaxWidth ?? 130)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (text as NSString).size(withAttributes: attrs).width > maxWidth {
            var cut = text
            while !cut.isEmpty, ((cut + "…") as NSString).size(withAttributes: attrs).width > maxWidth {
                cut.removeLast()
            }
            text = cut.trimmingCharacters(in: .whitespaces) + "…"
        }
        return " " + text
    }

    // MARK: - Меню

    private func buildMenu() {
        menu.delegate = self
        // Управляем доступностью пунктов сами — иначе AppKit включит их обратно.
        menu.autoenablesItems = false

        let cardItem = NSMenuItem()
        cardItem.view = nowPlayingView
        menu.addItem(cardItem)

        // «Переподключиться» появляется только когда Discord отвалился.
        menu.addItem(reconnectSeparator)
        menu.addItem(reconnectItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Выйти", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items where item.action != nil {
            item.target = self
        }
        updateReconnectItem()
    }

    private func updateReconnectItem() {
        var connected = false
        if case .connected = discordStatus { connected = true }
        reconnectItem.isHidden = connected
        reconnectSeparator.isHidden = connected
    }

    func menuWillOpen(_ menu: NSMenu) {
        settings.close()
        onMenuWillOpen?()
        refreshMenuContents()
    }

    private func refreshMenuContents() {
        var cover: NSImage?
        if let track, let url = track.coverURL(size: config.menuCoverSize) {
            let key = url.absoluteString
            cover = covers.image(for: url, then: { [weak self] image in
                guard let self, self.track?.coverURL(size: self.config.menuCoverSize)?.absoluteString == key else { return }
                self.nowPlayingView.update(track: self.track, cover: image, fallbackMessage: self.fallbackMessage)
                self.lastMenuCoverKey = key
            })
            if cover != nil { lastMenuCoverKey = key }
        }

        nowPlayingView.update(track: track, cover: cover, fallbackMessage: fallbackMessage)
        updateReconnectItem()
    }

    private var fallbackMessage: String {
        switch sourceStatus {
        case .connected: return "плеер на паузе или пуст"
        case .notRunning: return "запусти Яндекс Музыку"
        case .noPlayerWindow: return "окно плеера закрыто"
        case .inspectorUnavailable(let why): return why
        }
    }

    // MARK: - Действия

    @objc private func openYandexMusic() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "ru.yandex.desktop.music")
        if let app = apps.first {
            app.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "ru.yandex.desktop.music") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc private func copyTrack() {
        guard let track, !track.isEmpty else { return }
        let text: String
        if !track.url.isEmpty {
            text = track.url
        } else {
            let query = [track.artist, track.title].filter { !$0.isEmpty }.joined(separator: " ")
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            text = "https://music.yandex.ru/search?text=\(encoded)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openSettings() {
        menu.cancelTracking()
        // Ждём, пока меню закроется, и выпускаем поповер из-под той же иконки.
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.settings.toggle(relativeTo: button)
        }
    }

    @objc private func reconnect() { onReconnect?() }

    @objc private func quit() { onQuit?() }
}
