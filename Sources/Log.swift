import Foundation

enum Log {
    private static let queue = DispatchQueue(label: "ymrpc.log")
    private static let maxBytes = 200_000

    static var verbose = false

    private static var fileURL: URL { Config.directory.appendingPathComponent("log.txt") }

    static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        write("DEBUG", message())
    }

    static func info(_ message: @autoclosure () -> String) { write("INFO", message()) }
    static func warn(_ message: @autoclosure () -> String) { write("WARN", message()) }
    static func error(_ message: @autoclosure () -> String) { write("ERROR", message()) }

    private static func write(_ level: String, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) [\(level)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: Config.directory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            var size: UInt64 = 0
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                size = handle.offsetInFile
                try? handle.close()
            }
            // обрезаем
            if size > UInt64(maxBytes) * 2, let data = try? Data(contentsOf: fileURL) {
                try? data.suffix(maxBytes).write(to: fileURL, options: .atomic)
            }
        }
    }
}
