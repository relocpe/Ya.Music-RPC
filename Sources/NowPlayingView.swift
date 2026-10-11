import AppKit
import CoreImage

/// Полоска прогресса: тонкая в покое, при наведении толще и с ползунком.
final class ProgressBarView: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var isActive: Bool = true { didSet { needsDisplay = true } }
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var isScrubbing = false
    var onScrub: ((Double) -> Void)?
    private var isHovered = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let big = isHovered || isScrubbing
        let barHeight: CGFloat = big ? 6 : 4
        let knob: CGFloat = 11
        let inset = knob / 2
        let usable = bounds.width - inset * 2
        let y = (bounds.height - barHeight) / 2
        let radius = barHeight / 2
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: NSRect(x: inset, y: y, width: usable, height: barHeight), xRadius: radius, yRadius: radius).fill()

        let clamped = min(max(progress, 0), 1)
        let fillWidth = max(usable * CGFloat(clamped), barHeight)
        (isActive || isScrubbing ? accent : NSColor.secondaryLabelColor).setFill()
        if clamped > 0 {
            NSBezierPath(roundedRect: NSRect(x: inset, y: y, width: fillWidth, height: barHeight), xRadius: radius, yRadius: radius).fill()
        }
        if big {
            let cx = inset + usable * CGFloat(clamped)
            let knobRect = NSRect(x: cx - knob / 2, y: (bounds.height - knob) / 2, width: knob, height: knob)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 2
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knobRect).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func mouseDown(with event: NSEvent) { isScrubbing = true; updateScrub(event, commit: false) }
    override func mouseDragged(with event: NSEvent) { updateScrub(event, commit: false) }
    override func mouseUp(with event: NSEvent) { updateScrub(event, commit: true); isScrubbing = false; needsDisplay = true }

    private func updateScrub(_ event: NSEvent, commit: Bool) {
        let inset: CGFloat = 5.5
        let x = convert(event.locationInWindow, from: nil).x - inset
        let fraction = min(max(Double(x / max(bounds.width - inset * 2, 1)), 0), 1)
        progress = fraction
        isActive = true
        if commit { onScrub?(fraction) }
    }
}

/// Карточка «Сейчас играет» на подложке из размытой обложки.
final class NowPlayingView: NSView {
    static let width: CGFloat = 272

    var onCommand: ((PlayerCommand) -> Void)?
    var onOpenPlayer: (() -> Void)?
    var onCopyLink: (() -> Void)?

    private let backdrop = NSImageView()
    private let tint = NSView()
    private let coverButton = NSButton(frame: .zero)
    private let placeholderView = NSImageView()
    private let titleLabel = NowPlayingView.makeLabel(size: 13, weight: .semibold, color: .labelColor)
    private let artistLabel = NowPlayingView.makeLabel(size: 12, weight: .regular, color: .secondaryLabelColor)
    private let elapsedLabel = NowPlayingView.makeTimeLabel()
    private let remainingLabel = NowPlayingView.makeTimeLabel()
    private let progressBar = ProgressBarView()
    private let likeButton = NowPlayingView.makeTransportButton(symbol: "heart", pointSize: 13)
    private let linkButton = NowPlayingView.makeTransportButton(symbol: "link", pointSize: 12)
    private let shuffleButton = NowPlayingView.makeTransportButton(symbol: "shuffle", pointSize: 12)
    private let repeatButton = NowPlayingView.makeTransportButton(symbol: "repeat", pointSize: 12)
    private let shuffleDot = NowPlayingView.makeDot()
    private let repeatDot = NowPlayingView.makeDot()
    private let prevButton = NowPlayingView.makeTransportButton(symbol: "backward.fill", pointSize: 13)
    private let playWell = NSView(frame: .zero)
    private let playButton = NowPlayingView.makeTransportButton(symbol: "play.fill", pointSize: 13)
    private let nextButton = NowPlayingView.makeTransportButton(symbol: "forward.fill", pointSize: 13)

    private var duration: Double?
    private var accent = NSColor.controlAccentColor
    private var liked = false
    private var shuffleOn = false
    private var repeatMode: RepeatMode = .off
    private var shownCover: NSImage?
    private var hasShownCover = false

    override var isFlipped: Bool { true }

    init() {
        let pad: CGFloat = 16
        let cover: CGFloat = 72
        let W = NowPlayingView.width
        super.init(frame: NSRect(x: 0, y: 0, width: W, height: 0))

        backdrop.imageScaling = .scaleAxesIndependently
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 12
        backdrop.layer?.masksToBounds = true
        addSubview(backdrop)
        tint.wantsLayer = true
        tint.layer?.cornerRadius = 12
        addSubview(tint)

        coverButton.frame = NSRect(x: pad, y: pad, width: cover, height: cover)
        coverButton.isBordered = false
        coverButton.imagePosition = .imageOnly
        coverButton.imageScaling = .scaleProportionallyUpOrDown
        coverButton.wantsLayer = true
        coverButton.layer?.cornerRadius = 8
        coverButton.layer?.masksToBounds = true
        coverButton.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
        coverButton.target = self
        coverButton.action = #selector(coverTapped)
        coverButton.toolTip = "Открыть Яндекс Музыку"
        addSubview(coverButton)

        placeholderView.frame = coverButton.frame
        placeholderView.imageScaling = .scaleNone
        placeholderView.contentTintColor = .tertiaryLabelColor
        placeholderView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        addSubview(placeholderView, positioned: .below, relativeTo: coverButton)

        // Текст по центру обложки, иконки ссылки и лайка — на линии названия.
        let icon: CGFloat = 22
        let textX = pad + cover + 12
        let titleY = pad + cover / 2 - 19
        likeButton.frame = NSRect(x: W - pad - icon + 3, y: titleY - 1, width: icon, height: icon)
        linkButton.frame = NSRect(x: likeButton.frame.minX - icon - 2, y: titleY - 1, width: icon, height: icon)
        let textW = linkButton.frame.minX - 4 - textX
        titleLabel.frame = NSRect(x: textX, y: titleY, width: textW, height: 19)
        artistLabel.frame = NSRect(x: textX, y: titleY + 21, width: W - pad - textX, height: 17)
        addSubview(titleLabel)
        addSubview(artistLabel)

        likeButton.toolTip = "Нравится"
        likeButton.target = self
        likeButton.action = #selector(likeTapped)
        addSubview(likeButton)
        linkButton.toolTip = "Скопировать ссылку на трек"
        linkButton.contentTintColor = .secondaryLabelColor
        linkButton.target = self
        linkButton.action = #selector(linkTapped)
        addSubview(linkButton)

        // Кнопки управления.
        var y = pad + cover + 12
        let playSize: CGFloat = 34
        let sideSize: CGFloat = 24
        let extra: CGFloat = 22
        let gap: CGFloat = 16
        let extraGap: CGFloat = 14
        let rowWidth = extra + extraGap + sideSize + gap + playSize + gap + sideSize + extraGap + extra
        var x = (W - rowWidth) / 2

        shuffleButton.frame = NSRect(x: x, y: y + (playSize - extra) / 2, width: extra, height: extra)
        shuffleButton.toolTip = "Перемешать"
        shuffleDot.frame = NSRect(x: shuffleButton.frame.midX - 2, y: shuffleButton.frame.maxY + 1, width: 4, height: 4)
        x += extra + extraGap
        prevButton.frame = NSRect(x: x, y: y + (playSize - sideSize) / 2, width: sideSize, height: sideSize)
        x += sideSize + gap
        playWell.frame = NSRect(x: x, y: y, width: playSize, height: playSize)
        playWell.wantsLayer = true
        playWell.layer?.cornerRadius = playSize / 2
        playButton.frame = playWell.bounds
        playWell.addSubview(playButton)
        x += playSize + gap
        nextButton.frame = NSRect(x: x, y: y + (playSize - sideSize) / 2, width: sideSize, height: sideSize)
        x += sideSize + extraGap
        repeatButton.frame = NSRect(x: x, y: y + (playSize - extra) / 2, width: extra, height: extra)
        repeatButton.toolTip = "Повтор"
        repeatDot.frame = NSRect(x: repeatButton.frame.midX - 2, y: repeatButton.frame.maxY + 1, width: 4, height: 4)

        // Назад/вперёд — нейтральные, акцент только у play и полоски.
        prevButton.contentTintColor = .labelColor
        nextButton.contentTintColor = .labelColor
        for button in [shuffleButton, prevButton, playButton, nextButton, repeatButton] { button.target = self }
        shuffleButton.action = #selector(shuffleTapped)
        prevButton.action = #selector(prevTapped)
        playButton.action = #selector(playTapped)
        nextButton.action = #selector(nextTapped)
        repeatButton.action = #selector(repeatTapped)
        [shuffleButton, shuffleDot, prevButton, playWell, nextButton, repeatButton, repeatDot].forEach(addSubview)

        y += playSize + 8
        progressBar.frame = NSRect(x: pad - 5.5, y: y, width: W - pad * 2 + 11, height: 14)
        progressBar.onScrub = { [weak self] fraction in self?.scrubbed(fraction) }
        addSubview(progressBar)

        y += 14
        elapsedLabel.frame = NSRect(x: pad, y: y, width: 80, height: 13)
        addSubview(elapsedLabel)
        remainingLabel.frame = NSRect(x: W - pad - 80, y: y, width: 80, height: 13)
        remainingLabel.alignment = .right
        addSubview(remainingLabel)

        y += 13 + 10
        let cardInset: CGFloat = 6
        backdrop.frame = NSRect(x: cardInset, y: cardInset, width: W - cardInset * 2, height: y - cardInset)
        tint.frame = backdrop.frame
        frame = NSRect(x: 0, y: 0, width: W, height: y + 2)
        applyAccent(accent, animated: false)
        applyTint()
        applyLikeIcon()
        applyModeIcons()
    }

    required init?(coder: NSCoder) { fatalError("не используется") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    func update(track: TrackState?, cover: NSImage?, fallbackMessage: String) {
        let coverChanged = !hasShownCover || cover !== shownCover
        if coverChanged {
            fade(coverButton)
            fade(backdrop)
            coverButton.image = cover
            backdrop.image = cover?.blurredBackdrop()
            shownCover = cover
            hasShownCover = true
            if let cover, let color = cover.dominantColor() {
                applyAccent(color, animated: true)
            } else {
                applyAccent(.controlAccentColor, animated: true)
            }
        }
        placeholderView.isHidden = cover != nil
        coverButton.alphaValue = (track?.isPlaying == false) ? 0.55 : 1

        let enabled = track != nil
        prevButton.isEnabled = enabled
        playButton.isEnabled = enabled
        nextButton.isEnabled = enabled
        likeButton.isEnabled = enabled
        linkButton.isEnabled = enabled
        shuffleButton.isEnabled = enabled && (track?.hasShuffle ?? false)
        repeatButton.isEnabled = enabled && (track?.hasRepeat ?? false)

        guard let track else {
            duration = nil
            liked = false
            shuffleOn = false
            repeatMode = .off
            titleLabel.stringValue = "Ничего не играет"
            titleLabel.toolTip = nil
            artistLabel.stringValue = fallbackMessage
            if !progressBar.isScrubbing {
                progressBar.progress = 0
                progressBar.isActive = false
                elapsedLabel.stringValue = ""
                remainingLabel.stringValue = ""
            }
            setPlaySymbol(playing: false)
            applyLikeIcon()
            applyModeIcons()
            return
        }

        titleLabel.stringValue = track.title.isEmpty ? "Без названия" : track.title
        titleLabel.toolTip = track.title
        artistLabel.stringValue = track.artist
        artistLabel.toolTip = track.artist
        duration = track.duration
        liked = track.liked
        shuffleOn = track.shuffle
        repeatMode = track.repeatMode
        progressBar.isActive = track.isPlaying
        setPlaySymbol(playing: track.isPlaying)
        applyLikeIcon()
        applyModeIcons()

        if progressBar.isScrubbing { return }
        if let position = track.position, let duration = track.duration, duration > 0 {
            progressBar.progress = position / duration
            elapsedLabel.stringValue = TrackState.formatTime(position)
            remainingLabel.stringValue = "−" + TrackState.formatTime(max(duration - position, 0))
        } else {
            progressBar.progress = 0
            elapsedLabel.stringValue = track.position.map(TrackState.formatTime) ?? ""
            remainingLabel.stringValue = ""
        }
    }

    private func fade(_ view: NSView) {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.22
        view.layer?.add(transition, forKey: "fade")
    }

    private func applyTint() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        tint.layer?.backgroundColor = (dark ? NSColor.black.withAlphaComponent(0.42) : NSColor.white.withAlphaComponent(0.5)).cgColor
        tint.layer?.borderWidth = 0.5
        tint.layer?.borderColor = NSColor.white.withAlphaComponent(dark ? 0.08 : 0.3).cgColor
    }

    private func applyAccent(_ color: NSColor, animated: Bool) {
        var rgb = color.usingColorSpace(.deviceRGB) ?? color
        // Слишком кислотные цвета слегка приглушаем.
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s > 0.8 && b > 0.85 {
            rgb = NSColor(deviceHue: h, saturation: 0.72, brightness: 0.85, alpha: 1)
        }
        accent = rgb
        if animated, let layer = playWell.layer {
            let anim = CABasicAnimation(keyPath: "backgroundColor")
            anim.fromValue = layer.backgroundColor
            anim.toValue = rgb.cgColor
            anim.duration = 0.22
            layer.add(anim, forKey: "bg")
        }
        playWell.layer?.backgroundColor = rgb.cgColor
        progressBar.accent = rgb
        // Контраст иконки с кругом: тёмная иконка, если белая даст меньше 3:1.
        let luma = 0.2126 * lin(rgb.redComponent) + 0.7152 * lin(rgb.greenComponent) + 0.0722 * lin(rgb.blueComponent)
        let whiteContrast = 1.05 / (luma + 0.05)
        playButton.contentTintColor = whiteContrast < 3 ? NSColor.black.withAlphaComponent(0.85) : .white
        applyModeIcons()
    }

    private func lin(_ c: CGFloat) -> CGFloat {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private func applyLikeIcon() {
        let name = liked ? "heart.fill" : "heart"
        likeButton.image = NSImage(systemSymbolName: name, accessibilityDescription: "Нравится")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        likeButton.contentTintColor = liked ? .systemRed : .secondaryLabelColor
    }

    private func applyModeIcons() {
        shuffleButton.contentTintColor = shuffleOn ? accent : .secondaryLabelColor
        shuffleDot.isHidden = !shuffleOn
        shuffleDot.layer?.backgroundColor = accent.cgColor

        let repeatName = repeatMode == .one ? "repeat.1" : "repeat"
        repeatButton.image = NSImage(systemSymbolName: repeatName, accessibilityDescription: "Повтор")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        repeatButton.contentTintColor = repeatMode == .off ? .secondaryLabelColor : accent
        repeatDot.isHidden = repeatMode == .off
        repeatDot.layer?.backgroundColor = accent.cgColor
    }

    private func setPlaySymbol(playing: Bool) {
        let name = playing ? "pause.fill" : "play.fill"
        playButton.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
    }

    private func scrubbed(_ fraction: Double) {
        guard let duration, duration > 0 else { return }
        let seconds = fraction * duration
        elapsedLabel.stringValue = TrackState.formatTime(seconds)
        remainingLabel.stringValue = "−" + TrackState.formatTime(max(duration - seconds, 0))
        onCommand?(.seek(seconds))
    }

    @objc private func coverTapped() { onOpenPlayer?() }
    @objc private func linkTapped() {
        onCopyLink?()
        linkButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        linkButton.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.linkButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            self?.linkButton.contentTintColor = .secondaryLabelColor
        }
    }
    @objc private func likeTapped() { liked.toggle(); applyLikeIcon(); onCommand?(.like) }
    @objc private func shuffleTapped() { shuffleOn.toggle(); applyModeIcons(); onCommand?(.shuffle) }
    @objc private func repeatTapped() { repeatMode = repeatMode.next; applyModeIcons(); onCommand?(.cycleRepeat) }
    @objc private func prevTapped() { onCommand?(.prev) }
    @objc private func playTapped() { onCommand?(.toggle) }
    @objc private func nextTapped() { onCommand?(.next) }

    private static func makeLabel(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        return label
    }

    private static func makeTimeLabel() -> NSTextField {
        let label = makeLabel(size: 10, weight: .medium, color: .secondaryLabelColor)
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        return label
    }

    private static func makeDot() -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2
        dot.isHidden = true
        return dot
    }

    private static func makeTransportButton(symbol: String, pointSize: CGFloat) -> NSButton {
        let button = NSButton(frame: .zero)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .labelColor
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
        button.sendAction(on: .leftMouseUp)
        return button
    }
}

extension NSImage {
    /// Маленькая сильно размытая копия обложки для подложки карточки.
    func blurredBackdrop() -> NSImage? {
        var rect = NSRect(origin: .zero, size: size)
        guard let cg = cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let side = 64
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let small = ctx.makeImage() else { return nil }
        let input = CIImage(cgImage: small)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 7).cropped(to: input.extent)
        let saturated = blurred.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.4])
        guard let out = NowPlayingView.ciContext.createCGImage(saturated, from: input.extent) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: side, height: side))
    }
}

extension NowPlayingView {
    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
}
