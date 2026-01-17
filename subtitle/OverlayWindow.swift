import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    static let overlayAppearanceChanged = Notification.Name("overlayAppearanceChanged")
}

final class OverlayWindowController: NSWindowController {
    static let shared = OverlayWindowController()

    private var hosting: NSHostingView<OverlayCaptionView>?
    private var subscriptions = Set<AnyCancellable>()
    private var config = OverlayConfig()
    private let state = OverlayState()
    private weak var transcriberRef: CaptureTranscriber?
    @available(macOS 26.0, *)
    private weak var modernTranscriberRef: ModernCaptureTranscriber? {
        get { _modernTranscriberRef as? ModernCaptureTranscriber }
        set { _modernTranscriberRef = newValue }
    }
    private weak var _modernTranscriberRef: AnyObject?
    private var bottomInset: CGFloat = 0

    private var panel: NSPanel? {
        return window as? NSPanel
    }

    func show(transcriber: CaptureTranscriber) {
        if window == nil {
            createWindow()
        }
        self.transcriberRef = transcriber
        _modernTranscriberRef = nil

        let fixedWidth: CGFloat = config.fixedPixelWidth ?? ((NSScreen.main?.visibleFrame.width ?? 1280) * config.widthRatio)
        let view = OverlayCaptionView(transcriber: transcriber, state: state, config: config, fixedWidth: fixedWidth)
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        self.hosting = hosting

        window?.contentView = hosting
        window?.isReleasedWhenClosed = false
        window?.orderFrontRegardless()

        // Reposition on text and screen changes
        transcriber.$currentOriginal
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.state.objectWillChange.send() }
            .store(in: &subscriptions)

        transcriber.$currentTranslated
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.state.objectWillChange.send() }
            .store(in: &subscriptions)

        transcriber.$recentEntries
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.state.objectWillChange.send() }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.fitAndPosition() }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: .overlayAppearanceChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.fitAndPosition() }
            .store(in: &subscriptions)

        // Initial position/size
        fitAndPosition()

        // Always allow dragging the bubble window
        setDragEnabled(true)
    }
    
    @available(macOS 26.0, *)
    func show(modernTranscriber: ModernCaptureTranscriber) {
        if window == nil {
            createWindow()
        }
        self.modernTranscriberRef = modernTranscriber
        self.transcriberRef = nil

        let fixedWidth: CGFloat = config.fixedPixelWidth ?? ((NSScreen.main?.visibleFrame.width ?? 1280) * config.widthRatio)
        let view = OverlayCaptionView(modernTranscriber: modernTranscriber, state: state, config: config, fixedWidth: fixedWidth)
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        self.hosting = hosting

        window?.contentView = hosting
        window?.isReleasedWhenClosed = false
        window?.orderFrontRegardless()

        // Reposition on text and screen changes
        modernTranscriber.$currentOriginal
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.state.objectWillChange.send()
            }
            .store(in: &subscriptions)

        modernTranscriber.$currentTranslated
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.state.objectWillChange.send()
            }
            .store(in: &subscriptions)

        modernTranscriber.$recentEntries
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.state.objectWillChange.send()
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
            .sink { [weak self] _ in self?.fitAndPosition() }
            .store(in: &subscriptions)

        fitAndPosition()
        setDragEnabled(true)
    }

    func hide() {
        subscriptions.removeAll()
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
            let currentWidth = hosting.frame.width
            if #available(macOS 26.0, *), let modern = modernTranscriberRef {
                hosting.rootView = OverlayCaptionView(modernTranscriber: modern, state: state, config: config, fixedWidth: currentWidth)
            } else if let legacy = transcriberRef {
                hosting.rootView = OverlayCaptionView(transcriber: legacy, state: state, config: config, fixedWidth: currentWidth)
            }
        }
    }

    private func createWindow() {
        let screen = NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        // Initial size: wider and taller to accommodate bilingual text
        let initialFrame = NSRect(x: screenFrame.midX - 300, y: screenFrame.minY + 80, width: 600, height: 150)

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
        
        // 设置最小和最大尺寸
        panel.minSize = NSSize(width: 200, height: 60)
        panel.maxSize = NSSize(width: 1200, height: 400)
        
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
        
        // Keep current size (or initial size)
        let width = window.frame.width
        let height = window.frame.height

        let centerX = visible.minX + clamp(state.xRatio, 0.05, 0.95) * visible.width
        let centerY = visible.minY + clamp(state.yRatio, 0.05, 0.95) * visible.height
        let x = centerX - width / 2
        let y = centerY - height / 2
        
        let newFrame = NSRect(x: x, y: y, width: width, height: height)
        window.setFrame(newFrame, display: true)
        window.orderFrontRegardless()
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
}
