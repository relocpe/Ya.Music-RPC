import Foundation

enum CDPError: LocalizedError {
    case noTarget
    case badResponse(String)
    case remote(String)
    case timeout(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .noTarget: return "инспектор не отдал ни одной цели"
        case .badResponse(let s): return "неожиданный ответ: \(s)"
        case .remote(let s): return s
        case .timeout(let m): return "таймаут на \(m)"
        case .disconnected: return "соединение закрыто"
        }
    }
}

/// Клиент Chrome DevTools Protocol поверх WebSocket. Говорит с Node-инспектором
/// главного процесса Electron: один сокет, ответы разбираются по id запроса.
/// Состояние защищено `lock`, поэтому класс безопасно передавать между задачами.
final class CDPConnection: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var isClosed = false

    private init(task: URLSessionWebSocketTask, session: URLSession) {
        self.task = task
        self.session = session
    }

    /// Спрашивает у инспектора список целей и подключается к первой.
    static func connect(port: Int, timeout: TimeInterval = 5) async throws -> CDPConnection {
        let listURL = URL(string: "http://127.0.0.1:\(port)/json/list")!
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)

        let (data, _) = try await session.data(from: listURL)
        guard
            let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let wsString = targets.compactMap({ $0["webSocketDebuggerUrl"] as? String }).first,
            let wsURL = URL(string: wsString)
        else { throw CDPError.noTarget }

        let wsTask = session.webSocketTask(with: wsURL)
        let conn = CDPConnection(task: wsTask, session: session)
        wsTask.resume()
        conn.pump()
        return conn
    }

    func close() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        waiting.values.forEach { $0(.failure(CDPError.disconnected)) }
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    private func pump() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.failEverything(error)
            case .success(let message):
                switch message {
                case .string(let text): self.dispatch(text)
                case .data(let data): self.dispatch(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
                self.pump()
            }
        }
    }

    private func dispatch(_ text: String) {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let id = object["id"] as? Int
        else { return } // события протокола нам не нужны
        takePending(id)?(.success(object))
    }

    private func failEverything(_ error: Error) {
        lock.lock()
        let waiting = pending
        pending.removeAll()
        isClosed = true
        lock.unlock()
        waiting.values.forEach { $0(.failure(error)) }
    }

    /// Захваты блокировки живут в синхронных помощниках — так они не пересекают
    /// точки приостановки async-функции.
    private func nextRequestID() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        if isClosed { throw CDPError.disconnected }
        let id = nextID
        nextID += 1
        return id
    }

    private func register(_ id: Int, _ handler: @escaping (Result<[String: Any], Error>) -> Void) {
        lock.lock(); defer { lock.unlock() }
        pending[id] = handler
    }

    /// Ровно одно возобновление: отвечает тот, кто первым забрал handler.
    private func takePending(_ id: Int) -> ((Result<[String: Any], Error>) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }

    private func send(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id = try nextRequestID()
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let body = try JSONSerialization.data(withJSONObject: payload)

        return try await withCheckedThrowingContinuation { continuation in
            register(id) { continuation.resume(with: $0) }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.takePending(id)?(.failure(CDPError.timeout(method)))
            }

            task.send(.string(String(decoding: body, as: UTF8.self))) { [weak self] error in
                guard let error else { return }
                self?.takePending(id)?(.failure(error))
            }
        }
    }

    /// Выполняет выражение в главном процессе Electron и возвращает его значение.
    @discardableResult
    func evaluate(_ expression: String, awaitPromise: Bool = true, timeout: TimeInterval = 6) async throws -> Any? {
        let response = try await send(
            "Runtime.evaluate",
            [
                "expression": expression,
                "returnByValue": true,
                "awaitPromise": awaitPromise,
                "silent": false,
            ],
            timeout: timeout
        )
        guard let result = response["result"] as? [String: Any] else {
            throw CDPError.badResponse(String(describing: response).prefix(200).description)
        }
        if let details = result["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            let text = (exception?["description"] as? String)
                ?? (details["text"] as? String)
                ?? "исключение в инспекторе"
            throw CDPError.remote(String(text.prefix(300)))
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    /// Оборачивает строку в корректный JS-литерал, чтобы вставлять код в код.
    static func jsLiteral(_ string: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [string], options: [])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast()) // снимаем внешние [ ]
    }
}
