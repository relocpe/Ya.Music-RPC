import AppKit
import SwiftUI
import Combine

@MainActor
final class SettingsWindowController: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private weak var anchor: NSStatusBarButton?
    private var frameObserver: NSObjectProtocol?
    private weak var hosting: NSView?
    private var modelSub: AnyCancellable?
    private var windowObservers: [NSObjectProtocol] = []

    private func fitContent() {
        guard let popover, popover.isShown, let hosting,
              let container = popover.contentViewController?.view else { return }
        hosting.frame = container.bounds
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        if popover.contentSize != size {
            let wasAnimating = popover.animates
            popover.animates = false
            popover.contentSize = size
            popover.animates = wasAnimating
        }
        hosting.frame = container.bounds
    }
    var onReconnect: (() -> Void)?

    // правый край айтема не двигается, цепляем стрелку к нему
    private func anchorRect(for button: NSStatusBarButton) -> NSRect {
        let side: CGFloat = min(22, button.bounds.width)
        return NSRect(x: button.bounds.maxX - side, y: 0, width: side, height: button.bounds.height)
    }

    var isShown: Bool { popover?.isShown ?? false }

    func toggle(relativeTo button: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let model = SettingsModel()
        let view = SettingsView(model: model, onReconnect: { [weak self] in self?.onReconnect?() })
        // Размер считаем сами: NSHostingController с .preferredContentSize
        // при смене ширины в строке меню растягивал содержимое и сдвигал его влево.
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        let host = NSViewController()
        host.view = container
        self.hosting = hosting
        modelSub = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fitContent() } }
        }
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.contentViewController = host
        p.contentSize = size
        p.delegate = self
        popover = p
        NSApp.activate(ignoringOtherApps: true)
        anchor = button
        button.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: button, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reanchor() }
        }
        // Окно иконки сначала меняет размер, а потом отдельно сдвигается,
        // поэтому слушаем и его перемещение, и его ресайз.
        if let window = button.window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.reanchor() } })
            }
        }
        p.show(relativeTo: anchorRect(for: button), of: button, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
    }

    func close() { popover?.performClose(nil) }

    private var reanchorPending = false

    // ширина кнопки поменялась — показываем поповер заново (повторный show его только двигает)
    func reanchor() {
        guard popover?.isShown == true, !reanchorPending else { return }
        reanchorPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reanchorPending = false
                guard let popover = self.popover, popover.isShown, let anchor = self.anchor else { return }
                anchor.superview?.layoutSubtreeIfNeeded()
                self.fitContent()
                let wasAnimating = popover.animates
                popover.animates = false
                popover.show(relativeTo: self.anchorRect(for: anchor), of: anchor, preferredEdge: .minY)
                popover.animates = wasAnimating
                self.fitContent()
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        modelSub = nil
        hosting = nil
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
    }
}

/// Состояние окна. Без @State: у Command Line Tools нет плагина макросов SwiftUI.
@MainActor
private final class SettingsModel: ObservableObject {
    @Published var config = Config.load() {
        didSet { if config != oldValue { config.saveQuietly() } }
    }
    @Published var launchAtLogin = LaunchAtLogin.isEnabled {
        didSet {
            guard launchAtLogin != oldValue else { return }
            LaunchAtLogin.set(enabled: launchAtLogin)
            let real = LaunchAtLogin.isEnabled
            if real != launchAtLogin { launchAtLogin = real }
        }
    }
    @Published var reconnected = false
    @Published var draftWidth: Double = Config.load().menuBarMaxWidth ?? 130
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let onReconnect: () -> Void

    private var config: Config { model.config }

    private var textMode: Binding<String> {
        Binding(
            get: { config.showTextInMenuBar ? (config.menuBarText ?? "artist") : "none" },
            set: { value in
                model.config.showTextInMenuBar = value != "none"
                if value != "none" { model.config.menuBarText = value }
            }
        )
    }

    private var maxWidth: Binding<Double> { $model.draftWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 14)

            Divider().opacity(0.6)

            section("Общие") {
                row("Запускать при входе", subtitle: LaunchAtLogin.blockedReason) {
                    Toggle("", isOn: $model.launchAtLogin)
                        .disabled(LaunchAtLogin.blockedReason != nil)
                }
            }

            Divider().opacity(0.6).padding(.horizontal, 16)

            section("Строка меню") {
                row("Обложка трека") {
                    Toggle("", isOn: $model.config.showCoverInMenuBar)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Текст рядом с иконкой")
                        .font(.system(size: 13))
                    Picker("", selection: textMode) {
                        Text("Исполнитель").tag("artist")
                        Text("Трек").tag("title")
                        Text("Нет").tag("none")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if config.showTextInMenuBar {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Максимальная ширина")
                                .font(.system(size: 13))
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(maxWidth.wrappedValue)) pt")
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                        Slider(value: maxWidth, in: 60...240, step: 10) { editing in
                            if !editing { model.config.menuBarMaxWidth = model.draftWidth }
                        }
                        .controlSize(.small)
                    }
                }
            }

            Divider().opacity(0.6).padding(.horizontal, 16)

            section("Discord") {
                row("Статус «Слушает»", subtitle: "Вместо «Играет» в профиле") {
                    Toggle("", isOn: $model.config.useListeningActivityType)
                }
            }

            Divider().opacity(0.6)

            HStack {
                Button {
                    onReconnect()
                    model.reconnected = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.reconnected = false }
                } label: {
                    Label(model.reconnected ? "Переподключаю…" : "Переподключить",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.small)
                Spacer()
                Button("config.json") {
                    config.saveQuietly()
                    NSWorkspace.shared.selectFile(Config.fileURL.path, inFileViewerRootedAtPath: Config.directory.path)
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 300)
        .toggleStyle(.switch)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.8, blue: 0.2), Color(red: 1, green: 0.55, blue: 0.1)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "music.note")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.8))
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Настройки")
                    .font(.system(size: 14, weight: .semibold))
                Text("Ya.Music RPC")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func row<Control: View>(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            control()
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

// png-снапшот поповера для ревью дизайна
@MainActor
func renderSettingsSnapshot(to path: String, dark: Bool) {
    let root = SettingsView(model: SettingsModel(), onReconnect: {})
        .background(Color(nsColor: .windowBackgroundColor))
    let host = NSHostingView(rootView: root)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.appearance = host.appearance
    host.layoutSubtreeIfNeeded()
    host.display()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

