import Foundation

/// Discord слушает локальный unix-сокет $TMPDIR/discord-ipc-N.
/// Протокол простой: 4 байта опкода + 4 байта длины (little endian) + JSON.
final class DiscordRPC {
    enum Status: Equatable {
        case disconnected(String)
        case connected(String)

        var description: String {
            switch self {
            case .disconnected(let why): return why.isEmpty ? "не подключён" : "не подключён — \(why)"
            case .connected(let name): return "подключён как «\(name)»"
            }
        }
    }

    /// Discord требует Application ID. Свой создаётся бесплатно (см. README) и
    /// задаётся в config.json (`discordClientId`) или переменной YA_MUSIC_RPC_CLIENT_ID.
    struct KnownApp: Equatable {
        let id: String
        let name: String
    }

    private enum Opcode: UInt32 {
        case handshake = 0
        case frame = 1
        case close = 2
        case ping = 3
        case pong = 4
    }

    private let queue = DispatchQueue(label: "ymrpc.discord")
    private let lock = NSLock()

    private var fd: Int32 = -1
    private var clientID = ""
    private var useListeningType = true
    private var showSearchButton = false
    private var coverSize = 400

    private var _status: Status = .disconnected("подключаюсь…")
    private var resolvedApp: KnownApp?
    private var nextRetryAt = Date.distantPast
    private var lastSentAt = Date.distantPast

    /// Последняя отправленная активность — чтобы не долбить Discord лишними кадрами
    /// (он ограничивает SET_ACTIVITY примерно пятью запросами за 20 секунд).
    private var lastIdentity: String?
    private var lastPlaying: Bool?
    private var lastStart: Double?
    private var lastWasCleared = false

    var status: Status {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    private func setStatus(_ new: Status) {
        lock.lock(); _status = new; lock.unlock()
    }

    func apply(config: Config) {
        queue.async {
            let newClientID = config.effectiveClientId
            let clientChanged = self.clientID != newClientID
            // Всё, что меняет вид присутствия: иначе правка конфига проявилась бы
            // только со следующим треком — дедупликация не пустила бы кадр.
            let presenceChanged = self.useListeningType != config.useListeningActivityType
                || self.showSearchButton != config.showSearchButton
                || self.coverSize != config.discordCoverSize

            self.clientID = newClientID
            self.useListeningType = config.useListeningActivityType
            self.showSearchButton = config.showSearchButton
            self.coverSize = config.discordCoverSize

            if clientChanged {
                self.disconnect()
                self.resolvedApp = nil
                self.nextRetryAt = .distantPast
            }
            if clientChanged || presenceChanged {
                self.resetActivityMemory()
            }
        }
    }

    /// Свой ID из конфига — единственный кандидат: если он неверный, честнее
    /// сказать об этом, чем молча подменить чужим.
    private var candidates: [KnownApp] {
        if !clientID.isEmpty {
            return [KnownApp(id: clientID, name: "свой Application ID")]
        }
        return []
    }

    /// Главная точка входа: вызывается на каждом опросе, сама решает, слать ли кадр.
    func update(with track: TrackState?) {
        queue.async { self.updateOnQueue(track) }
    }

    func shutdown() {
        queue.sync {
            if fd >= 0 { _ = sendActivity(nil) }
            disconnect()
        }
    }

    func reconnectSoon() {
        queue.async {
            self.disconnect()
            self.nextRetryAt = .distantPast
            self.resetActivityMemory()
        }
    }

    // MARK: - Логика обновления

    private func resetActivityMemory() {
        lastIdentity = nil
        lastPlaying = nil
        lastStart = nil
        lastWasCleared = false
    }

    private func updateOnQueue(_ track: TrackState?) {
        guard ensureConnected() else { return }

        guard let track, !track.isEmpty else {
            // Плеер молчит — снимаем присутствие, но только один раз.
            if !lastWasCleared {
                if sendActivity(nil) {
                    resetActivityMemory()
                    lastWasCleared = true
                }
            }
            return
        }

        let start = track.isPlaying ? startTimestamp(for: track) : nil
        guard shouldSend(track: track, start: start) else { return }

        if sendActivity(track) {
            Log.debug("Discord принял активность: \(track.title) — \(track.artist)\(track.isPlaying ? "" : " (пауза)")")
            lastIdentity = track.identity
            lastPlaying = track.isPlaying
            lastStart = start
            lastWasCleared = false
            lastSentAt = Date()
        }
    }

    private func startTimestamp(for track: TrackState) -> Double? {
        guard let position = track.position else { return nil }
        return Date().timeIntervalSince1970 - position
    }

    private func shouldSend(track: TrackState, start: Double?) -> Bool {
        if lastIdentity != track.identity { return true }
        if lastPlaying != track.isPlaying { return true }
        // Начало трека «стоит на месте», пока играем ровно; сдвиг — это перемотка.
        if let start, let lastStart, abs(start - lastStart) > 3 { return true }
        if start != nil && lastStart == nil { return true }
        // Разрешаем редкое обновление на случай, если Discord потерял активность.
        return Date().timeIntervalSince(lastSentAt) > 120
    }

    // MARK: - Кадры

    private func sendActivity(_ track: TrackState?) -> Bool {
        var args: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier]

        if let track {
            args["activity"] = Self.activityPayload(
                for: track,
                useListeningType: useListeningType,
                showSearchButton: showSearchButton,
                coverSize: coverSize
            )
        } else {
            args["activity"] = NSNull()
        }

        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": args,
            "nonce": UUID().uuidString,
        ]

        guard writeFrame(.frame, payload) else {
            disconnect()
            setStatus(.disconnected("обрыв при отправке"))
            return false
        }

        // Ответ вычитываем, иначе он копится в буфере сокета.
        switch readFrame(timeout: 2) {
        case .some((_, let object)):
            if let event = object["evt"] as? String, event == "ERROR" {
                let message = ((object["data"] as? [String: Any])?["message"] as? String) ?? "Discord отклонил активность"
                Log.warn("Discord: \(message)")
                setStatus(.disconnected(message))
                return false
            }
            if Log.verbose, let stored = object["data"] as? [String: Any],
               let json = try? JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys]) {
                Log.debug("Discord сохранил: \(String(decoding: json, as: UTF8.self))")
            }
            return true
        case .none:
            return true // ответ не дождались — не повод рвать соединение
        }
    }

    /// Собирает объект активности. Чистая функция — её же печатает `--diagnose`.
    ///
    /// Раскладка карточки в Discord:
    ///   узкий статус «Слушает <name>» — исполнитель
    ///   <details>                     — название трека
    static func activityPayload(
        for track: TrackState,
        useListeningType: Bool,
        showSearchButton: Bool,
        coverSize: Int
    ) -> [String: Any] {
        var activity: [String: Any] = [:]
        if useListeningType { activity["type"] = 2 } // «Слушает»

        let headline = track.artist.isEmpty ? track.title : track.artist
        activity["name"] = discordField(headline.isEmpty ? "Неизвестный трек" : headline)

        var details = track.title
        if !track.isPlaying { details = details.isEmpty ? "на паузе" : "⏸ " + details }
        if !details.isEmpty { activity["details"] = discordField(details) }

        // Альбом в присутствии не показываем вовсе — в карточке он лишний.
        // Подпись к обложке не ставим по той же причине.
        if let cover = track.coverURL(size: coverSize)?.absoluteString {
            activity["assets"] = ["large_image": cover]
        }

        if track.isPlaying, let position = track.position {
            let now = Date().timeIntervalSince1970
            var timestamps: [String: Any] = ["start": Int((now - position).rounded())]
            if let duration = track.duration, duration > position {
                timestamps["end"] = Int((now + (duration - position)).rounded())
            }
            activity["timestamps"] = timestamps
        }

        if showSearchButton, let url = searchURL(for: track) {
            activity["buttons"] = [["label": "Слушать", "url": url]]
        }

        return activity
    }

    private static func searchURL(for track: TrackState) -> String? {
        let query = "\(track.artist) \(track.title)".trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty,
              let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return "https://music.yandex.ru/search?text=\(escaped)"
    }

    /// Discord требует от details/state от 2 до 128 символов.
    private static func discordField(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count > 128 { value = String(value.prefix(127)) + "…" }
        if value.count == 1 { value += " " }
        return value
    }

    // MARK: - Сокет

    private enum HandshakeResult {
        case ready
        case invalidClientID(String)
        case failed
    }

    private func ensureConnected() -> Bool {
        if fd >= 0 { return true }
        if Date() < nextRetryAt { return false }

        let sockets = (0..<10)
            .map { (NSTemporaryDirectory() as NSString).appendingPathComponent("discord-ipc-\($0)") }
            .filter { FileManager.default.fileExists(atPath: $0) }

        guard !sockets.isEmpty else {
            nextRetryAt = Date().addingTimeInterval(10)
            setStatus(.disconnected("Discord не запущен"))
            return false
        }

        guard !candidates.isEmpty else {
            nextRetryAt = Date().addingTimeInterval(60)
            setStatus(.disconnected("не задан Discord Application ID (см. README)"))
            Log.warn("Discord Application ID не задан: укажи discordClientId в config.json или переменную YA_MUSIC_RPC_CLIENT_ID")
            return false
        }

        // Уже подобранное приложение пробуем первым, чтобы не перебирать заново.
        let all = candidates
        let order = all.filter { $0.id == resolvedApp?.id } + all.filter { $0.id != resolvedApp?.id }
        var rejection: String?

        for path in sockets {
            for app in order {
                switch connect(to: path, clientID: app.id) {
                case .ready:
                    resolvedApp = app
                    setStatus(.connected(app.name))
                    Log.info("Discord: подключился через \(path), приложение «\(app.name)» (\(app.id))")
                    resetActivityMemory()
                    return true
                case .invalidClientID(let message):
                    rejection = message
                    Log.warn("Discord отверг Application ID \(app.id): \(message)")
                case .failed:
                    break
                }
            }
        }

        resolvedApp = nil
        nextRetryAt = Date().addingTimeInterval(rejection != nil ? 60 : 10)
        setStatus(.disconnected(rejection ?? "Discord не отвечает"))
        return false
    }

    private func connect(to path: String, clientID: String) -> HandshakeResult {
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { return .failed }

        var enabled: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { close(handle); return .failed }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let connected = withUnsafePointer(to: &address) { pointer -> Bool in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(handle, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { close(handle); return .failed }

        fd = handle
        guard writeFrame(.handshake, ["v": 1, "client_id": clientID]) else {
            disconnect()
            return .failed
        }
        guard let (opcode, object) = readFrame(timeout: 4) else {
            disconnect()
            return .failed
        }
        // На неизвестный или чужой Application ID Discord отвечает кадром CLOSE —
        // это сигнал перебрать следующего кандидата, а не «Discord недоступен».
        if opcode == Opcode.close.rawValue {
            let message = (object["message"] as? String) ?? "Discord отклонил Application ID"
            disconnect()
            return .invalidClientID(message)
        }
        guard (object["evt"] as? String) == "READY" else {
            disconnect()
            return .failed
        }
        return .ready
    }

    private func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    private func writeFrame(_ opcode: Opcode, _ payload: [String: Any]) -> Bool {
        guard fd >= 0, let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var header = Data()
        withUnsafeBytes(of: opcode.rawValue.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { header.append(contentsOf: $0) }
        return writeAll(header + body)
    }

    private func writeAll(_ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while sent < data.count {
                let written = write(fd, base.advanced(by: sent), data.count - sent)
                if written <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                sent += written
            }
            return true
        }
    }

    /// Читает один кадр. На PING отвечает PONG и читает следующий.
    private func readFrame(timeout: TimeInterval) -> (UInt32, [String: Any])? {
        var deadlineTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadlineTimeout, socklen_t(MemoryLayout<timeval>.size))

        for _ in 0..<4 {
            guard let header = readExactly(8) else { return nil }
            let opcode = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }.littleEndian
            let length = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }.littleEndian
            guard length < 1_000_000 else { return nil }
            let body = length > 0 ? readExactly(Int(length)) : Data()
            guard let body else { return nil }
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

            if opcode == Opcode.ping.rawValue {
                _ = writeFrame(.pong, object)
                continue
            }
            return (opcode, object)
        }
        return nil
    }

    private func readExactly(_ count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let got = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base.advanced(by: received), count - received)
            }
            if got == 0 { return nil }
            if got < 0 {
                if errno == EINTR { continue }
                return nil
            }
            received += got
        }
        return Data(buffer)
    }
}
