import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    static let overlayAppearanceChanged = Notification.Name("overlayAppearanceChanged")
    static let overlayWindowFrameDidChange = Notification.Name("overlayWindowFrameDidChange")
}

@MainActor
final class OverlayWindowController: NSWindowController {
    static let shared = OverlayWindowController()

    private struct OverlayBindings {
        let snapshot: () -> OverlayContentSnapshot
        let currentOriginal: AnyPublisher<String, Never>
        let currentTranslated: AnyPublisher<String, Never>
        let recentEntries: AnyPublisher<[CaptionEntry], Never>
    }

    private var hosting: TransparentHostingView<OverlayCaptionView>?
    private let demoBackdropController = OverlayDemoBackdropController()
    private var subscriptions = Set<AnyCancellable>()
    private var config = OverlayConfig()
    private let state = OverlayState()
    private let content = OverlayContentState()
    private var showsDemoBackdrop = false

    private var panel: NSPanel? {
        window as? NSPanel
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    func show(transcriber: CaptureTranscriber) {
        show(
            using: OverlayBindings(
                snapshot: {
                    OverlayContentSnapshot(
                        currentOriginal: transcriber.currentOriginal,
                        currentTranslated: transcriber.currentTranslated,
                        recentEntries: transcriber.recentEntries
                    )
                },
                currentOriginal: transcriber.$currentOriginal.eraseToAnyPublisher(),
                currentTranslated: transcriber.$currentTranslated.eraseToAnyPublisher(),
                recentEntries: transcriber.$recentEntries.eraseToAnyPublisher()
            )
        )
    }

    @available(macOS 26.0, *)
    func show(modernTranscriber: ModernCaptureTranscriber) {
        show(
            using: OverlayBindings(
                snapshot: {
                    OverlayContentSnapshot(
                        currentOriginal: modernTranscriber.currentOriginal,
                        currentTranslated: modernTranscriber.currentTranslated,
                        recentEntries: modernTranscriber.recentEntries
                    )
                },
                currentOriginal: modernTranscriber.$currentOriginal.eraseToAnyPublisher(),
                currentTranslated: modernTranscriber.$currentTranslated.eraseToAnyPublisher(),
                recentEntries: modernTranscriber.$recentEntries.eraseToAnyPublisher()
            )
        )
    }

    func hide() {
        subscriptions.removeAll()
        content.reset()
        showsDemoBackdrop = false
        demoBackdropController.hide()
        window?.close()
        window = nil
        hosting = nil
    }

    func showDemo(original: String, translated: String) {
        if window == nil {
            createWindow()
        }

        subscriptions.removeAll()
        content.apply(
            snapshot: OverlayContentSnapshot(
                currentOriginal: original,
                currentTranslated: translated,
                recentEntries: []
            )
        )

        let initialWidth = panel?.frame.width ?? config.fixedPixelWidth ?? ((NSScreen.main?.visibleFrame.width ?? 1280) * config.widthRatio)
        installSurfaceView(width: initialWidth)
        window?.isReleasedWhenClosed = false
        showsDemoBackdrop = true
        fitAndPosition()
        syncDemoBackdropFrame()
        window?.orderFrontRegardless()
        notifyOverlayFrameChange()
        setDragEnabled(true)
    }

    func setDragEnabled(_ enabled: Bool) {
        state.dragEnabled = enabled
        if let panel = self.panel {
            // 不设置 isMovableByWindowBackground，以便边缘可以用于调整大小
            // 拖动功能通过内容区域的鼠标事件处理
            panel.ignoresMouseEvents = false
        }
    }
    
    func updateMaxLines(_ lines: Int) {
        config.maxLines = lines
        rebuildRootView()
    }
    
    func updateFontSize(_ size: CGFloat) {
        config.fontSize = size
        rebuildRootView()
    }

    func updateBackgroundOpacity(_ opacity: Double) {
        config.backgroundOpacity = CGFloat(opacity)
        rebuildRootView()
    }

    func updateBackgroundStyle(_ style: OverlayBackgroundStyle) {
        config.backgroundStyle = style
        rebuildRootView()
    }

    private func rebuildRootView() {
        guard window != nil else { return }
        let currentWidth = max(window?.frame.width ?? 0, config.fixedPixelWidth ?? 800)
        installSurfaceView(width: currentWidth)
        applyWindowSizing()
    }

    private func show(using bindings: OverlayBindings) {
        if window == nil {
            createWindow()
        }

        subscriptions.removeAll()
        content.apply(snapshot: bindings.snapshot())

        let initialWidth = panel?.frame.width ?? config.fixedPixelWidth ?? ((NSScreen.main?.visibleFrame.width ?? 1280) * config.widthRatio)
        installSurfaceView(width: initialWidth)
        window?.isReleasedWhenClosed = false
        showsDemoBackdrop = false
        demoBackdropController.hide()
        window?.orderFrontRegardless()

        bindings.currentOriginal
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.content.currentOriginal = $0
            }
            .store(in: &subscriptions)

        bindings.currentTranslated
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.content.currentTranslated = $0
            }
            .store(in: &subscriptions)

        bindings.recentEntries
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.content.recentEntries = $0
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.fitAndPosition()
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: .overlayAppearanceChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.fitAndPosition()
            }
            .store(in: &subscriptions)

        fitAndPosition()
        notifyOverlayFrameChange()
        setDragEnabled(true)
    }

    private func createWindow() {
        let screen = NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let initialWidth = config.fixedPixelWidth ?? 800
        let initialFrame = NSRect(
            x: screenFrame.midX - initialWidth / 2,
            y: screenFrame.minY + 80,
            width: initialWidth,
            height: 150
        )

        let style: NSWindow.StyleMask = [.borderless, .resizable, .nonactivatingPanel]
        let panel = NSPanel(contentRect: initialFrame,
                            styleMask: style,
                            backing: .buffered,
                            defer: false)

        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.delegate = self
        
        // Allow free resize while keeping the overlay in a practical range.
        panel.minSize = NSSize(width: 320, height: 60)
        panel.maxSize = NSSize(width: 1400, height: 400)
        
        // 允许通过内容区域拖动（但不影响边缘调整大小）
        panel.isMovableByWindowBackground = true
        
        self.window = panel
    }

    private func fitAndPosition() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        
        let width = window.frame.width
        let height = window.frame.height

        let centerX = visible.minX + clamp(state.xRatio, 0.05, 0.95) * visible.width
        let centerY = visible.minY + clamp(state.yRatio, 0.05, 0.95) * visible.height
        let x = centerX - width / 2
        let y = centerY - height / 2
        
        let newFrame = NSRect(x: x, y: y, width: width, height: height)
        window.setFrame(newFrame, display: true)
        syncDemoBackdropFrame()
        window.orderFrontRegardless()
        notifyOverlayFrameChange()
    }

    private func applyWindowSizing() {
        guard let panel else { return }
        panel.minSize = NSSize(width: 320, height: 60)
        panel.maxSize = NSSize(width: 1400, height: 400)
    }

    private func installSurfaceView(width: CGFloat) {
        let view = OverlayCaptionView(content: content, config: config, fixedWidth: width)
        let hosting = TransparentHostingView(rootView: view)
        self.hosting = hosting
        window?.contentView = hosting
    }

    private func notifyOverlayFrameChange() {
        guard let window else { return }
        NotificationCenter.default.post(
            name: .overlayWindowFrameDidChange,
            object: self,
            userInfo: ["size": NSValue(size: window.frame.size)]
        )
    }

    private func syncDemoBackdropFrame() {
        guard showsDemoBackdrop, let window else {
            demoBackdropController.hide()
            return
        }

        demoBackdropController.show(around: window.frame, on: window.screen ?? NSScreen.main)
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
}

extension OverlayWindowController: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let xr = (center.x - visible.minX) / visible.width
        let yr = (center.y - visible.minY) / visible.height
        state.xRatio = clamp(xr, 0.05, 0.95)
        state.yRatio = clamp(yr, 0.05, 0.95)
        syncDemoBackdropFrame()
    }

    func windowDidResize(_ notification: Notification) {
        syncDemoBackdropFrame()
        notifyOverlayFrameChange()
    }
}

@MainActor
private final class OverlayDemoBackdropController: NSWindowController {
    func show(around overlayFrame: NSRect, on screen: NSScreen?) {
        if window == nil {
            createWindow()
        }

        guard let window else { return }
        window.setFrame(frame(for: overlayFrame, on: screen), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window?.close()
        window = nil
    }

    private func createWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = TransparentHostingView(rootView: OverlayDemoBackdropView())
        self.window = window
    }

    private func frame(for overlayFrame: NSRect, on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let targetWidth = min(max(overlayFrame.width + 240, 960), visible.width - 80)
        let targetHeight = min(max(overlayFrame.height + 180, 320), visible.height - 80)
        let originX = min(max(overlayFrame.midX - targetWidth / 2, visible.minX + 40), visible.maxX - targetWidth - 40)
        let originY = min(max(overlayFrame.midY - targetHeight / 2, visible.minY + 40), visible.maxY - targetHeight - 40)
        return NSRect(x: originX, y: originY, width: targetWidth, height: targetHeight)
    }
}

private struct OverlayDemoBackdropView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.11, green: 0.22, blue: 0.45),
                    Color(red: 0.07, green: 0.48, blue: 0.62),
                    Color(red: 0.88, green: 0.52, blue: 0.24)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 260, height: 260)
                .blur(radius: 34)
                .offset(x: -220, y: -70)

            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(Color.white.opacity(0.14))
                .frame(width: 280, height: 180)
                .blur(radius: 18)
                .offset(x: 180, y: 60)

            HStack(spacing: 24) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(index.isMultiple(of: 2) ? 0.14 : 0.08))
                        .frame(width: 110, height: 22 + CGFloat(index) * 18)
                        .rotationEffect(.degrees(-18))
                }
            }
            .offset(x: -40, y: 96)

            VStack(alignment: .leading, spacing: 10) {
                Text("Overlay Glass Test")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("彩色底板用于确认真实悬浮字幕是否正在采样窗口后景，而不是显示为单一纯色。")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .frame(maxWidth: 560, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(38)
        }
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
    }
}
