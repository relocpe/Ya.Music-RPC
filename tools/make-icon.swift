import AppKit

/// Рисует PNG-заготовки иконки приложения. Вызывается из tools/make-icon.sh,
/// который собирает из них AppIcon.icns. В обычной сборке не участвует.
@main
enum IconMaker {
    static let sizes = [16, 32, 64, 128, 256, 512, 1024]

    static func main() {
        let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        for size in sizes {
            guard let data = render(size: size) else {
                FileHandle.standardError.write(Data("не смог отрисовать \(size)px\n".utf8))
                exit(1)
            }
            let path = "\(outputDir)/icon_\(size).png"
            try? data.write(to: URL(fileURLWithPath: path))
            print("нарисовал \(path)")
        }
    }

    private static func render(size: Int) -> Data? {
        let side = CGFloat(size)
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        // Скруглённый квадрат по пропорциям Apple: радиус ≈ 22.37% стороны.
        let inset = side * 0.05
        let plate = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        let radius = plate.width * 0.2237
        NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).addClip()

        NSGradient(colors: [
            NSColor(calibratedRed: 0.33, green: 0.28, blue: 0.92, alpha: 1),
            NSColor(calibratedRed: 0.58, green: 0.23, blue: 0.80, alpha: 1),
            NSColor(calibratedRed: 0.88, green: 0.25, blue: 0.46, alpha: 1),
        ])?.draw(in: plate, angle: -60)

        guard let note = whiteNote(pointSize: plate.width * 0.5) else { return nil }
        let noteRect = NSRect(
            x: plate.midX - note.size.width / 2,
            y: plate.midY - note.size.height / 2,
            width: note.size.width,
            height: note.size.height
        )
        note.draw(in: noteRect)

        return bitmap.representation(using: .png, properties: [:])
    }

    /// SF-символ рисуется чёрным, поэтому перекрашиваем его в белый отдельной картинкой.
    private static func whiteNote(pointSize: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return nil }

        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }
}
