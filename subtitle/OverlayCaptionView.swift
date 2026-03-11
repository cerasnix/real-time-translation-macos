import SwiftUI
import AppKit

struct OverlayConfig {
    var maxLines: Int = 2
    var fontSize: CGFloat = 28
    var horizontalPadding: CGFloat = 16
    var verticalPadding: CGFloat = 10
    var cornerRadius: CGFloat = 10
    var backgroundOpacity: CGFloat = 0.65
    var backgroundStyle: OverlayBackgroundStyle = .glass
    var widthRatio: CGFloat = 0.8
    var fixedPixelWidth: CGFloat? = 800 // initial width for the floating window
}

enum OverlayBackgroundStyle: String, CaseIterable, Identifiable {
    case solid = "纯色"
    case material = "材质"
    case glass = "液态玻璃"

    var id: String { rawValue }
}

struct OverlayCaptionView: View {
    @ObservedObject var content: OverlayContentState
    var config: OverlayConfig
    var fixedWidth: CGFloat

    private var displayEntries: [CaptionEntry] {
        var entries = content.recentEntries
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
        content.currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentTranslatedText: String {
        content.currentTranslated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        GeometryReader { geometry in
            let entries = displayEntries
            if entries.isEmpty {
                Color.clear
            } else {
                captionBubble(entries: entries, maxWidth: geometry.size.width)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    @ViewBuilder
    private func captionBubble(entries: [CaptionEntry], maxWidth: CGFloat) -> some View {
        let resolvedWidth = maxWidth > 0 ? maxWidth : fixedWidth
        let bubbleWidth = max(240, resolvedWidth - config.horizontalPadding * 2)
        let textWidth = max(120, bubbleWidth - config.horizontalPadding * 2)
        let lines = buildLines(entries: entries, maxWidth: textWidth)
        let limit = max(1, config.maxLines)
        let clippedLines = lines.suffix(limit)

        let captionContent = VStack(spacing: 4) {
            ForEach(clippedLines) { line in
                Text(line.text)
                    .font(.system(size: line.isTranslation ? config.fontSize * 0.9 : config.fontSize,
                                  weight: line.isTranslation ? .medium : .semibold,
                                  design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(line.isTranslation ? Color.white.opacity(0.82) : Color.white)
            }
        }
        .frame(width: textWidth, alignment: .center)
        .fixedSize(horizontal: false, vertical: true)
        
        if config.backgroundStyle == .glass {
            NativeGlassContainer(
                cornerRadius: config.cornerRadius,
                style: .regular,
                tintColor: nativeGlassTintColor
            ) {
                captionContent
                    .padding(.horizontal, config.horizontalPadding)
                    .padding(.vertical, config.verticalPadding)
                    .frame(width: bubbleWidth, alignment: .center)
            }
            .frame(width: bubbleWidth)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            captionContent
                .padding(.horizontal, config.horizontalPadding)
                .padding(.vertical, config.verticalPadding)
                .frame(width: bubbleWidth, alignment: .center)
                .background(backgroundView())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}

private struct CaptionLine: Identifiable {
    let id: Int
    let text: String
    let isTranslation: Bool
}

private struct CaptionLayoutCacheKey: Hashable {
    let text: String
    let fontName: String
    let fontSizeTimesTen: Int
    let maxWidthTimesTwo: Int
}

private final class CaptionLayoutCache {
    static let shared = CaptionLayoutCache()

    private let lock = NSLock()
    private var cachedLines: [CaptionLayoutCacheKey: [String]] = [:]
    private let maxEntries = 512

    func wrappedLines(for text: String, font: NSFont, maxWidth: CGFloat) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard maxWidth > 0 else { return [trimmed] }

        let key = CaptionLayoutCacheKey(
            text: trimmed,
            fontName: font.fontName,
            fontSizeTimesTen: Int((font.pointSize * 10).rounded()),
            maxWidthTimesTwo: Int((maxWidth * 2).rounded())
        )

        lock.lock()
        if let lines = cachedLines[key] {
            lock.unlock()
            return lines
        }
        lock.unlock()

        let lines = Self.layoutLines(for: trimmed, font: font, maxWidth: maxWidth)

        lock.lock()
        if cachedLines.count >= maxEntries {
            cachedLines.removeAll(keepingCapacity: true)
        }
        cachedLines[key] = lines
        lock.unlock()

        return lines
    }

    private static func layoutLines(for text: String, font: NSFont, maxWidth: CGFloat) -> [String] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .paragraphStyle: paragraphStyle
            ]
        )

        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.lineBreakMode = .byWordWrapping

        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let nsText = text as NSString
        var lines: [String] = []
        var glyphIndex = 0

        while glyphIndex < layoutManager.numberOfGlyphs {
            var lineRange = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
            let characterRange = layoutManager.characterRange(forGlyphRange: lineRange, actualGlyphRange: nil)
            let line = nsText.substring(with: characterRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                lines.append(line)
            }

            let nextIndex = NSMaxRange(lineRange)
            guard nextIndex > glyphIndex else { break }
            glyphIndex = nextIndex
        }

        return lines.isEmpty ? [text] : lines
    }
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
                for line in wrappedLines(entry.original, font: originalFont, maxWidth: maxWidth) {
                    lines.append(CaptionLine(id: lines.count, text: line, isTranslation: false))
                }
            }
            if !entry.translated.isEmpty {
                for line in wrappedLines(entry.translated, font: translatedFont, maxWidth: maxWidth) {
                    lines.append(CaptionLine(id: lines.count, text: line, isTranslation: true))
                }
            }
        }

        return lines
    }

    func wrappedLines(_ text: String, font: NSFont, maxWidth: CGFloat) -> [String] {
        CaptionLayoutCache.shared.wrappedLines(for: text, font: font, maxWidth: maxWidth)
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
            shape.fill(Color.black.opacity(config.backgroundOpacity))
        }
    }

    var nativeGlassTintColor: NSColor {
        let normalized = min(max((Double(config.backgroundOpacity) - 0.2) / 0.8, 0.0), 1.0)
        let alpha = 0.01 + (normalized * 0.10)
        return NSColor.black.withAlphaComponent(alpha)
    }
}
