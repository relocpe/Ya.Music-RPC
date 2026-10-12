import AppKit

// кеш обложек, чтобы не качать на каждое открытие меню
@MainActor
final class CoverLoader {
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private var inFlight: Set<String> = []
    private let limit = 12

    func image(for url: URL, then: @escaping (NSImage) -> Void) -> NSImage? {
        let key = url.absoluteString
        if let cached = cache[key] { return cached }
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)

        Task { [weak self] in
            defer { self?.inFlight.remove(key) }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard
                let (data, response) = try? await URLSession.shared.data(for: request),
                (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                let image = NSImage(data: data)
            else {
                Log.debug("обложка не скачалась: \(key)")
                return
            }
            guard let self else { return }
            self.store(image, for: key)
            then(image)
        }
        return nil
    }

    private func store(_ image: NSImage, for key: String) {
        cache[key] = image
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
        }
    }
}

extension NSImage {
    func roundedThumbnail(side: CGFloat, cornerRadius: CGFloat, alpha: CGFloat = 1) -> NSImage {
        let target = NSSize(width: side, height: side)
        let result = NSImage(size: target)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        let clip = NSBezierPath(roundedRect: NSRect(origin: .zero, size: target),
                                xRadius: cornerRadius, yRadius: cornerRadius)
        clip.addClip()

        // вписываем с сохранением пропорций
        let source = size
        var drawRect = NSRect(origin: .zero, size: target)
        if source.width > 0, source.height > 0 {
            let scale = max(target.width / source.width, target.height / source.height)
            let scaled = NSSize(width: source.width * scale, height: source.height * scale)
            drawRect = NSRect(x: (target.width - scaled.width) / 2,
                              y: (target.height - scaled.height) / 2,
                              width: scaled.width, height: scaled.height)
        }
        draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: alpha)
        result.unlockFocus()
        result.isTemplate = false
        return result
    }
}


extension NSImage {
    func dominantColor() -> NSColor? {
        let sample = 24
        var rect = NSRect(origin: .zero, size: size)
        guard let cg = cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: sample * sample * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: sample,
            height: sample,
            bitsPerComponent: 8,
            bytesPerRow: sample * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: sample, height: sample))

        var rSum = 0.0, gSum = 0.0, bSum = 0.0, wSum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.5 else { continue }
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let sat = maxC == 0 ? 0 : (maxC - minC) / maxC
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            guard sat > 0.12, luma > 0.12, luma < 0.92 else { continue }
            let w = a * (0.35 + sat) * (1 - abs(luma - 0.5))
            rSum += r * w
            gSum += g * w
            bSum += b * w
            wSum += w
        }
        guard wSum > 0 else { return nil }
        return NSColor(calibratedRed: rSum / wSum, green: gSum / wSum, blue: bSum / wSum, alpha: 1)
    }
}
