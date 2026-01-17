import SwiftUI
import AppKit

struct OverlayConfig {
    var maxLines: Int = 2
    var fontSize: CGFloat = 28
    var horizontalPadding: CGFloat = 16
    var verticalPadding: CGFloat = 10
    var cornerRadius: CGFloat = 10
    var backgroundOpacity: CGFloat = 0.65
    var backgroundStyle: OverlayBackgroundStyle = .solid
    var widthRatio: CGFloat = 0.8 // legacy ratio (unused when fixedPixelWidth != nil)
    var fixedPixelWidth: CGFloat? = 800 // 固定像素宽度，优先于比例
}

enum OverlayBackgroundStyle: String, CaseIterable, Identifiable {
    case solid = "纯色"
    case material = "材质"
    case glass = "玻璃"

    var id: String { rawValue }
}

struct OverlayCaptionView: View {
    @ObservedObject var state: OverlayState
    var config: OverlayConfig
    var fixedWidth: CGFloat
    
    // 支持两种转录器
    private var legacyTranscriber: CaptureTranscriber?
    @available(macOS 26.0, *)
    private var modernTranscriber: ModernCaptureTranscriber? {
        _modernTranscriber as? ModernCaptureTranscriber
    }
    private var _modernTranscriber: Any?
    
    // 传统转录器初始化器
    init(transcriber: CaptureTranscriber, state: OverlayState, config: OverlayConfig, fixedWidth: CGFloat) {
        self.legacyTranscriber = transcriber
        self._modernTranscriber = nil
        self.state = state
        self.config = config
        self.fixedWidth = fixedWidth
    }
    
    // 新转录器初始化器
    @available(macOS 26.0, *)
    init(modernTranscriber: ModernCaptureTranscriber, state: OverlayState, config: OverlayConfig, fixedWidth: CGFloat) {
        self.legacyTranscriber = nil
        self._modernTranscriber = modernTranscriber
        self.state = state
        self.config = config
        self.fixedWidth = fixedWidth
    }

    private var displayEntries: [CaptionEntry] {
        var entries: [CaptionEntry] = []

        if #available(macOS 26.0, *), let modern = modernTranscriber {
            entries = modern.recentEntries
        } else if let legacy = legacyTranscriber {
            entries = legacy.recentEntries
        }

        let currentOriginal = currentOriginalText
        let currentTranslated = currentTranslatedText
        if !currentOriginal.isEmpty || !currentTranslated.isEmpty {
            let last = entries.last
            if last?.original != currentOriginal || last?.translated != currentTranslated {
                entries.append(CaptionEntry(original: currentOriginal, translated: currentTranslated))
            }
        }
        
        let maxEntries = max(4, config.maxLines * 2)
        if entries.count > maxEntries {
            entries = Array(entries.suffix(maxEntries))
        }

        return entries
    }

    private var currentOriginalText: String {
        var original = ""
        if #available(macOS 26.0, *), let modern = modernTranscriber {
            original = modern.currentOriginal
        } else if let legacy = legacyTranscriber {
            original = legacy.currentOriginal
        }
        return original.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentTranslatedText: String {
        var translated = ""
        if #available(macOS 26.0, *), let modern = modernTranscriber {
            translated = modern.currentTranslated
        } else if let legacy = legacyTranscriber {
            translated = legacy.currentTranslated
        }
        return translated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        GeometryReader { geometry in
            if displayEntries.isEmpty {
                Color.clear
            } else {
                captionBubble(entries: displayEntries, maxWidth: geometry.size.width)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    @ViewBuilder
    private func captionBubble(entries: [CaptionEntry], maxWidth: CGFloat) -> some View {
        let resolvedWidth = maxWidth > 0 ? maxWidth : fixedWidth
        let availableWidth = max(0, resolvedWidth - config.horizontalPadding * 2)
        let lines = buildLines(entries: entries, maxWidth: availableWidth)
        let limit = max(1, config.maxLines)
        let clippedLines = lines.suffix(limit)

        let content = VStack(spacing: 4) {
            ForEach(clippedLines) { line in
                Text(line.text)
                    .font(.system(size: line.isTranslation ? config.fontSize * 0.9 : config.fontSize,
                                  weight: line.isTranslation ? .medium : .semibold,
                                  design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(line.isTranslation ? Color(red: 0.8, green: 0.9, blue: 1.0) : .white)
                    .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 0)
            }
        }
        .padding(.horizontal, config.horizontalPadding)
        .padding(.vertical, config.verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        
        if config.backgroundStyle == .glass {
            ZStack {
                GlassEffectContainer {
                    glassBackground(opacity: config.backgroundOpacity)
                }
                content
            }
        } else {
            content.background(backgroundView())
        }
    }

}

private struct CaptionLine: Identifiable {
    let id = UUID()
    let text: String
    let isTranslation: Bool
}

private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

private extension OverlayCaptionView {
    func buildLines(entries: [CaptionEntry], maxWidth: CGFloat) -> [CaptionLine] {
        guard maxWidth > 0 else { return [] }
        var lines: [CaptionLine] = []

        let originalFont = NSFont.systemFont(ofSize: config.fontSize, weight: .semibold)
        let translatedFont = NSFont.systemFont(ofSize: config.fontSize * 0.9, weight: .medium)

        for entry in entries {
            if !entry.original.isEmpty {
                for line in wrapLines(entry.original, font: originalFont, maxWidth: maxWidth) {
                    lines.append(CaptionLine(text: line, isTranslation: false))
                }
            }
            if !entry.translated.isEmpty {
                for line in wrapLines(entry.translated, font: translatedFont, maxWidth: maxWidth) {
                    lines.append(CaptionLine(text: line, isTranslation: true))
                }
            }
        }

        return lines
    }

    func wrapLines(_ text: String, font: NSFont, maxWidth: CGFloat) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard maxWidth > 0 else { return [trimmed] }

        var results: [String] = []
        let segments = trimmed.components(separatedBy: .newlines).filter { !$0.isEmpty }

        for segment in segments {
            var current = ""
            for char in segment {
                let candidate = current + String(char)
                if textWidth(candidate, font: font) <= maxWidth || current.isEmpty {
                    current = candidate
                } else {
                    results.append(current)
                    current = String(char)
                }
            }
            if !current.isEmpty {
                results.append(current)
            }
        }

        return results
    }

    func textWidth(_ text: String, font: NSFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return (text as NSString).size(withAttributes: attrs).width
    }

    @ViewBuilder
    func backgroundView() -> some View {
        let shape = RoundedRectangle(cornerRadius: config.cornerRadius)
        switch config.backgroundStyle {
        case .solid:
            shape.fill(Color.black.opacity(config.backgroundOpacity))
        case .material:
            VisualEffectBackground(material: .hudWindow, blendingMode: .withinWindow, state: .active)
                .clipShape(shape)
                .opacity(config.backgroundOpacity)
        case .glass:
            VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow, state: .active)
                .clipShape(shape)
                .opacity(config.backgroundOpacity)
        }
    }

    func glassBackground(opacity: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: config.cornerRadius)
        let tintOpacity = max(0.05, min(0.25, opacity * 0.3))
        let shadeOpacity = max(0.0, min(0.25, (1 - opacity) * 0.2))
        return shape
            .glassEffect(in: shape)
            .tint(Color.white.opacity(tintOpacity))
            .overlay(
                shape.stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .overlay(
                shape.fill(Color.black.opacity(shadeOpacity))
            )
    }
}
