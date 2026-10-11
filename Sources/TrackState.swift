import Foundation

/// Что сейчас в плеере. `position`/`duration` могут быть nil: метаданные приходят
/// из Media Session, а время — из <audio>-элемента, и второй иногда ещё не найден.
struct TrackState: Equatable {
    var title: String
    var artist: String
    var album: String
    var coverURL: String?
    var isPlaying: Bool
    var position: Double?
    var duration: Double?
    var liked: Bool = false
    var shuffle: Bool = false
    var repeatMode: RepeatMode = .off
    var hasShuffle: Bool = false
    var hasRepeat: Bool = false
    var url: String = ""

    /// Идентификатор именно трека, без времени — по нему ловим смену песни.
    var identity: String { "\(title)\u{1}\(artist)\u{1}\(album)" }

    var isEmpty: Bool { title.isEmpty && artist.isEmpty }

    /// Обложки Яндекса лежат по URL вида .../<id>/400x400 — размер меняется подстановкой.
    func coverURL(size: Int) -> URL? {
        guard let base = coverURL, !base.isEmpty else { return nil }
        let resized = base.replacingOccurrences(
            of: "/\\d+x\\d+$",
            with: "/\(size)x\(size)",
            options: .regularExpression
        )
        return URL(string: resized) ?? URL(string: base)
    }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// Состояние связи с приложением Яндекс Музыки — показываем его в меню.
enum SourceStatus: Equatable {
    case notRunning
    case inspectorUnavailable(String)
    case noPlayerWindow
    case connected

    var description: String {
        switch self {
        case .notRunning: return "приложение не запущено"
        case .inspectorUnavailable(let why): return "нет доступа к плееру — \(why)"
        case .noPlayerWindow: return "окно плеера не найдено"
        case .connected: return "подключено"
        }
    }
}

/// Команды с карточки в меню-баре. Уходят в плеер через инспектор.
enum RepeatMode: String, Equatable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

enum PlayerCommand {
    case toggle
    case next
    case prev
    case seek(Double)
    case like
    case shuffle
    case cycleRepeat

    var logName: String {
        switch self {
        case .toggle: return "toggle"
        case .next: return "next"
        case .prev: return "prev"
        case .seek(let seconds): return String(format: "seek %.1f", seconds)
        case .like: return "like"
        case .shuffle: return "shuffle"
        case .cycleRepeat: return "repeat"
        }
    }
}

