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

    private var hosting: NSHostingView<OverlayCaptionView>?
    private var subscriptions = Set<AnyCancellable>()
    private var config = OverlayConfig()
    private let state = OverlayState()
    private let content = OverlayContentState()

    private var panel: NSPanel? {
        window as? NSPanel
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
        window?.orderOut(nil)
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
        if let hosting {
            let currentWidth = max(hosting.frame.width, config.fixedPixelWidth ?? 800)
            hosting.rootView = OverlayCaptionView(content: content, config: config, fixedWidth: currentWidth)
            applyWindowSizing()
        }
    }

    private func show(using bindings: OverlayBindings) {
        if window == nil {
            createWindow()
        }

        subscriptions.removeAll()
        content.apply(snapshot: bindings.snapshot())

        let initialWidth = panel?.frame.width ?? config.fixedPixelWidth ?? ((NSScreen.main?.visibleFrame.width ?? 1280) * config.widthRatio)
        let view = OverlayCaptionView(content: content, config: config, fixedWidth: initialWidth)
        let hosting = NSHostingView(rootView: view)
        self.hosting = hosting

        window?.contentView = hosting
        window?.isReleasedWhenClosed = false
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

        let style: NSWindow.StyleMask = [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel]
        let panel = NSPanel(contentRect: initialFrame,
                            styleMask: style,
                            backing: .buffered,
                            defer: false)

        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = false
        panel.level = .statusBar
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
        
        // Hide title bar and buttons for a clean look
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

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
        window.orderFrontRegardless()
        notifyOverlayFrameChange()
    }

    private func applyWindowSizing() {
        guard let panel else { return }
        panel.minSize = NSSize(width: 320, height: 60)
        panel.maxSize = NSSize(width: 1400, height: 400)
    }

    private func notifyOverlayFrameChange() {
        guard let window else { return }
        NotificationCenter.default.post(
            name: .overlayWindowFrameDidChange,
            object: self,
            userInfo: ["size": NSValue(size: window.frame.size)]
        )
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
    }

    func windowDidResize(_ notification: Notification) {
        notifyOverlayFrameChange()
    }
}
