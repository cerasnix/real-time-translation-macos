import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor
final class ViewModel: ObservableObject {
    enum ExportFormat {
        case plainText
        case srt

        var title: String {
            switch self {
            case .plainText:
                return "文本日志"
            case .srt:
                return "SRT 字幕"
            }
        }

        var suggestedFilename: String {
            switch self {
            case .plainText:
                return "subtitle-log.txt"
            case .srt:
                return "subtitle-captions.srt"
            }
        }

        var contentType: UTType {
            switch self {
            case .plainText:
                return .plainText
            case .srt:
                return UTType(filenameExtension: "srt") ?? .plainText
            }
        }
    }

    private enum DefaultsKey {
        static let translationSource = "settings.translationSource"
        static let translationTarget = "settings.translationTarget"
        static let maxLines = "settings.maxLines"
        static let fontSize = "settings.fontSize"
        static let backgroundOpacity = "settings.backgroundOpacity"
        static let backgroundStyle = "settings.backgroundStyle"
        static let previewExpanded = "settings.previewExpanded"
    }

    private let defaults: UserDefaults

    @Published var localeIdentifier: String
    @Published var overlayPreviewSize: CGSize
    @Published var isShowingTestOverlay: Bool = false
    @Published var isPreviewExpanded: Bool {
        didSet {
            defaults.set(isPreviewExpanded, forKey: DefaultsKey.previewExpanded)
        }
    }

    @Published var translationSource: String {
        didSet {
            defaults.set(translationSource, forKey: DefaultsKey.translationSource)
            let mapped = Self.mapToSpeechLocale(from: translationSource)
            localeIdentifier = mapped
            updateTranscriberTranslationPair()
            Task { await TranslationService.shared.prepare(sourceIdentifier: translationSource, targetIdentifier: translationTarget) }
            if isRunning {
                stop()
                start()
            }
        }
    }
    @Published var translationTarget: String {
        didSet {
            defaults.set(translationTarget, forKey: DefaultsKey.translationTarget)
            updateTranscriberTranslationPair()
            refreshCurrentTranslation()
            Task { await TranslationService.shared.prepare(sourceIdentifier: translationSource, targetIdentifier: translationTarget) }
        }
    }
    
    @Published var maxLines: Int {
        didSet {
            defaults.set(maxLines, forKey: DefaultsKey.maxLines)
            OverlayWindowController.shared.updateMaxLines(maxLines)
        }
    }
    
    @Published var fontSize: CGFloat {
        didSet {
            defaults.set(Double(fontSize), forKey: DefaultsKey.fontSize)
            OverlayWindowController.shared.updateFontSize(fontSize)
        }
    }

    @Published var backgroundOpacity: Double {
        didSet {
            defaults.set(backgroundOpacity, forKey: DefaultsKey.backgroundOpacity)
            OverlayWindowController.shared.updateBackgroundOpacity(backgroundOpacity)
        }
    }

    @Published var backgroundStyle: OverlayBackgroundStyle {
        didSet {
            defaults.set(backgroundStyle.rawValue, forKey: DefaultsKey.backgroundStyle)
            OverlayWindowController.shared.updateBackgroundStyle(backgroundStyle)
        }
    }
    
    // 根据系统版本选择转录器
    private let legacyTranscriber: CaptureTranscriber?
    @available(macOS 26.0, *)
    private var modernTranscriber: ModernCaptureTranscriber? {
        _modernTranscriber as? ModernCaptureTranscriber
    }
    private var _modernTranscriber: Any?
    private var cancellables = Set<AnyCancellable>()
    
    // 统一接口
    var isRunning: Bool {
        if #available(macOS 26.0, *), let modern = _modernTranscriber as? ModernCaptureTranscriber {
            return modern.isRunning
        } else if let legacy = legacyTranscriber {
            return legacy.isRunning
        }
        return false
    }
    
    var logText: String {
        if #available(macOS 26.0, *), let modern = _modernTranscriber as? ModernCaptureTranscriber {
            return modern.logText
        } else if let legacy = legacyTranscriber {
            return legacy.logText
        }
        return ""
    }
    
    var translatedLogText: String {
        if #available(macOS 26.0, *), let modern = _modernTranscriber as? ModernCaptureTranscriber {
            return modern.translatedLogText
        } else if let legacy = legacyTranscriber {
            return legacy.translatedLogText
        }
        return ""
    }
    
    var currentOriginal: String {
        if #available(macOS 26.0, *), let modern = _modernTranscriber as? ModernCaptureTranscriber {
            return modern.currentOriginal
        } else if let legacy = legacyTranscriber {
            return legacy.currentOriginal
        }
        return ""
    }
    
    var currentTranslated: String {
        if #available(macOS 26.0, *), let modern = _modernTranscriber as? ModernCaptureTranscriber {
            return modern.currentTranslated
        } else if let legacy = legacyTranscriber {
            return legacy.currentTranslated
        }
        return ""
    }
    
    var currentCombined: String {
        if #available(macOS 26.0, *), let modern = _modernTranscriber as? ModernCaptureTranscriber {
            return modern.currentCombined
        } else if let legacy = legacyTranscriber {
            return legacy.currentCombined
        }
        return ""
    }

    var recentEntries: [CaptionEntry] {
        if #available(macOS 26.0, *), let modern = _modernTranscriber as? ModernCaptureTranscriber {
            return modern.recentEntries
        } else if let legacy = legacyTranscriber {
            return legacy.recentEntries
        }
        return []
    }

    init(defaults: UserDefaults = .standard) {
        let launchesDemoOverlay = ProcessInfo.processInfo.arguments.contains("--demo-overlay")
        let savedSource = defaults.string(forKey: DefaultsKey.translationSource) ?? "en"
        let savedTarget = defaults.string(forKey: DefaultsKey.translationTarget) ?? "zh-Hans"
        let savedMaxLines = Self.clamp(defaults.object(forKey: DefaultsKey.maxLines) as? Int ?? 2, min: 1, max: 10)
        let savedFontSize = Self.clamp(CGFloat(defaults.object(forKey: DefaultsKey.fontSize) as? Double ?? 28), min: 12, max: 48)
        let savedBackgroundOpacity = Self.clamp(defaults.object(forKey: DefaultsKey.backgroundOpacity) as? Double ?? 0.65, min: 0.2, max: 1.0)
        let savedBackgroundStyle = OverlayBackgroundStyle(rawValue: defaults.string(forKey: DefaultsKey.backgroundStyle) ?? "") ?? .glass

        let savedPreviewExpanded = defaults.object(forKey: DefaultsKey.previewExpanded) as? Bool ?? true

        self.defaults = defaults
        isPreviewExpanded = savedPreviewExpanded
        translationSource = savedSource
        translationTarget = savedTarget
        maxLines = savedMaxLines
        fontSize = savedFontSize
        backgroundOpacity = savedBackgroundOpacity
        backgroundStyle = savedBackgroundStyle
        overlayPreviewSize = CGSize(width: 800, height: 150)
        localeIdentifier = Self.mapToSpeechLocale(from: savedSource)

        if #available(macOS 26.0, *) {
            print("[信息] 使用新的 SpeechAnalyzer API")
            let modern = ModernCaptureTranscriber()
            _modernTranscriber = modern
            legacyTranscriber = nil
            
            // 订阅变化
            modern.objectWillChange
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                .store(in: &cancellables)
        } else {
            print("[信息] 使用传统的 SFSpeechRecognizer API")
            let legacy = CaptureTranscriber()
            legacyTranscriber = legacy
            _modernTranscriber = nil
            
            // 订阅变化
            legacy.objectWillChange
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                .store(in: &cancellables)
        }
        NotificationCenter.default.publisher(for: .overlayWindowFrameDidChange)
            .compactMap { notification in
                (notification.userInfo?["size"] as? NSValue)?.sizeValue
            }
            .sink { [weak self] size in
                self?.overlayPreviewSize = size
            }
            .store(in: &cancellables)
        updateTranscriberTranslationPair()
        OverlayWindowController.shared.updateMaxLines(maxLines)
        OverlayWindowController.shared.updateFontSize(fontSize)
        OverlayWindowController.shared.updateBackgroundOpacity(backgroundOpacity)
        OverlayWindowController.shared.updateBackgroundStyle(backgroundStyle)

        if launchesDemoOverlay {
            Task { @MainActor [weak self] in
                self?.toggleTestOverlay()
            }
        }
    }

    func start() {
        if isShowingTestOverlay {
            OverlayWindowController.shared.hide()
            isShowingTestOverlay = false
        }

        let locale = Locale(identifier: localeIdentifier)
        updateTranscriberTranslationPair()
        Task { await TranslationService.shared.prepare(sourceIdentifier: translationSource, targetIdentifier: translationTarget) }

        if #available(macOS 26.0, *), let modern = _modernTranscriber as? ModernCaptureTranscriber {
            modern.start(locale: locale)
            OverlayWindowController.shared.show(modernTranscriber: modern)
        } else if let legacy = legacyTranscriber {
            legacy.start(locale: locale)
            OverlayWindowController.shared.show(transcriber: legacy)
        }
    }

    func stop() {
        if #available(macOS 26.0, *), let modern = _modernTranscriber as? ModernCaptureTranscriber {
            modern.stop()
        } else if let legacy = legacyTranscriber {
            legacy.stop()
        }
        OverlayWindowController.shared.hide()
        isShowingTestOverlay = false
    }

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }
    
    func logUserMessage(_ message: String) {
        if #available(macOS 26.0, *), let modern = _modernTranscriber as? ModernCaptureTranscriber {
            modern.appendUserLog(message)
        } else if let legacy = legacyTranscriber {
            legacy.appendUserLog(message)
        } else {
            print(message)
        }
    }

    func clearLogs() {
        if #available(macOS 26.0, *), let modern = _modernTranscriber as? ModernCaptureTranscriber {
            modern.clearLogs()
        } else if let legacy = legacyTranscriber {
            legacy.clearLogs()
        }
    }

    func exportLogText() -> String {
        var sections: [String] = []

        if !logText.isEmpty {
            sections.append("=== 状态与原文 ===\n\(logText)")
        }

        if !translatedLogText.isEmpty {
            sections.append("=== 翻译 ===\n\(translatedLogText)")
        }

        if !recentEntries.isEmpty {
            var recentSection = "=== 最终字幕 ===\n"
            for entry in recentEntries {
                recentSection += "[\(Self.logTimestampFormatter.string(from: entry.createdAt))]\n"
                if !entry.original.isEmpty {
                    recentSection += entry.original + "\n"
                }
                if !entry.translated.isEmpty {
                    recentSection += "译: " + entry.translated + "\n"
                }
                recentSection += "\n"
            }
            sections.append(recentSection.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return sections.joined(separator: "\n\n")
    }

    var hasExportableLog: Bool {
        !exportLogText().isEmpty
    }

    var hasExportableCaptions: Bool {
        !exportableCaptionEntries.isEmpty
    }

    func exportLogs() {
        export(format: .plainText)
    }

    func exportSRT() {
        export(format: .srt)
    }

    func export(format: ExportFormat) {
        let content: String
        switch format {
        case .plainText:
            content = exportLogText()
        case .srt:
            content = exportSRTText()
        }

        guard !content.isEmpty else {
            logUserMessage("[提示] 当前没有可导出的\(format.title)。")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = format.suggestedFilename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    self.logUserMessage("[信息] \(format.title)已保存: \(url.lastPathComponent)")
                } catch {
                    self.logUserMessage("[错误] 保存\(format.title)失败: \(error.localizedDescription)")
                }
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func exportSRTText() -> String {
        let entries = exportableCaptionEntries
        guard !entries.isEmpty else { return "" }

        let baseTime = entries[0].createdAt
        let minimumDuration: TimeInterval = 1.2
        let maximumDuration: TimeInterval = 6.0
        let cueGap: TimeInterval = 0.05

        return entries.enumerated().map { index, entry in
            let start = max(entry.createdAt.timeIntervalSince(baseTime), 0)
            let nextStart = index < entries.index(before: entries.endIndex)
                ? max(entries[index + 1].createdAt.timeIntervalSince(baseTime), start)
                : nil

            let end: TimeInterval
            if let nextStart {
                let preferredEnd = min(nextStart - cueGap, start + maximumDuration)
                end = max(start + minimumDuration, preferredEnd)
            } else {
                end = start + 3.0
            }

            let cueText = [
                entry.original.trimmingCharacters(in: .whitespacesAndNewlines),
                entry.translated.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

            return """
            \(index + 1)
            \(Self.srtTimestamp(for: start)) --> \(Self.srtTimestamp(for: end))
            \(cueText)
            """
        }
        .joined(separator: "\n\n")
    }

    private static func mapToSpeechLocale(from lang: String) -> String {
        switch lang {
        case "en": return "en-US"
        case "ja": return "ja-JP"
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "ko": return "ko-KR"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "es": return "es-ES"
        case "ru": return "ru-RU"
        case "it": return "it-IT"
        case "pt": return "pt-PT"
        default: return lang
        }
    }

    private static func clamp<T: Comparable>(_ value: T, min minValue: T, max maxValue: T) -> T {
        Swift.max(minValue, Swift.min(value, maxValue))
    }

    private var exportableCaptionEntries: [CaptionEntry] {
        recentEntries
            .filter { !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private static func srtTimestamp(for interval: TimeInterval) -> String {
        let clamped = max(0, interval)
        let totalMilliseconds = Int((clamped * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let seconds = (totalMilliseconds % 60_000) / 1_000
        let milliseconds = totalMilliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func updateTranscriberTranslationPair() {
        if #available(macOS 26.0, *), let modern = _modernTranscriber as? ModernCaptureTranscriber {
            modern.updateTranslationPair(sourceIdentifier: translationSource, targetIdentifier: translationTarget)
        } else if let legacy = legacyTranscriber {
            legacy.updateTranslationPair(sourceIdentifier: translationSource, targetIdentifier: translationTarget)
        }
    }

    private func refreshCurrentTranslation() {
        if #available(macOS 26.0, *), let modern = _modernTranscriber as? ModernCaptureTranscriber {
            modern.refreshCurrentTranslation()
        } else if let legacy = legacyTranscriber {
            legacy.refreshCurrentTranslation()
        }
    }

    func toggleTestOverlay() {
        if isShowingTestOverlay || OverlayWindowController.shared.isVisible {
            OverlayWindowController.shared.hide()
            isShowingTestOverlay = false
            return
        }

        let original = currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = currentTranslated.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastEntry = recentEntries.last

        let demoOriginal = !original.isEmpty ? original : (lastEntry?.original.isEmpty == false ? lastEntry!.original : defaultOverlaySample().original)
        let demoTranslated = !translated.isEmpty ? translated : (lastEntry?.translated.isEmpty == false ? lastEntry!.translated : defaultOverlaySample().translated)

        OverlayWindowController.shared.showDemo(original: demoOriginal, translated: demoTranslated)
        isShowingTestOverlay = true
    }

    private func defaultOverlaySample() -> (original: String, translated: String) {
        let original: String
        switch translationSource {
        case "ja":
            original = "これは権限なしで確認できるテスト字幕です"
        case "zh-Hans":
            original = "这是一个无需权限即可验证的测试字幕"
        default:
            original = "This is a test subtitle you can inspect without permissions."
        }

        let translated: String
        switch translationTarget {
        case "ja":
            translated = "これは権限なしで確認できるテスト字幕です"
        case "zh-Hans":
            translated = "这是一个无需权限即可验证的测试字幕"
        default:
            translated = "This is a test subtitle you can inspect without permissions."
        }

        return (original, translated)
    }
}

struct ContentView: View {
    @EnvironmentObject private var vm: ViewModel
    private let stageCornerRadius: CGFloat = 24
    private let nestedCornerRadius: CGFloat = 20

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 380)
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.prominentDetail)
        .toolbar { toolbarContent }
        .frame(minWidth: 980, minHeight: 700)
        .animation(.snappy(duration: 0.22), value: vm.isPreviewExpanded)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                vm.toggle()
            } label: {
                Label(vm.isRunning ? "停止" : "开始", systemImage: vm.isRunning ? "stop.circle.fill" : "play.circle.fill")
            }
            .help(vm.isRunning ? "停止捕获" : "开始捕获")
            .buttonStyle(.glassProminent)
            .tint(vm.isRunning ? .red : .accentColor)
            .keyboardShortcut(.space, modifiers: [])

            Button {
                vm.isPreviewExpanded.toggle()
            } label: {
                Image(systemName: vm.isPreviewExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
            }
            .help(vm.isPreviewExpanded ? "收起实时预览" : "显示实时预览")
            .accessibilityLabel(vm.isPreviewExpanded ? "收起预览" : "显示预览")
            .buttonStyle(.glass)
        }
        .sharedBackgroundVisibility(.visible)
    }

    private var sidebar: some View {
        SubtitleSettingsView()
            .navigationTitle("设置")
    }

    private var detailPane: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 20) {
                if vm.isPreviewExpanded {
                    previewSection(availableWidth: geometry.size.width - 48)
                }
                logPanel()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("实时字幕")
    }

    private func previewSection(availableWidth: CGFloat) -> some View {
        let stageHeight = previewStageHeight(for: availableWidth)
        let previewWindowSize = fittedPreviewWindowSize(in: CGSize(width: availableWidth, height: stageHeight))
        let bubbleWidth = max(260, min(previewWindowSize.width - 32, previewWindowSize.width * 0.88))

        return GroupBox {
            ZStack {
                PreviewBackdrop()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                OverlayPreviewBubble(
                    lines: previewLines(),
                    style: vm.backgroundStyle,
                    fontSize: vm.fontSize,
                    strength: vm.backgroundOpacity,
                    bubbleWidth: bubbleWidth
                )
                .frame(width: previewWindowSize.width, height: previewWindowSize.height)
                .shadow(color: Color.black.opacity(0.16), radius: 18, y: 10)
            }
            .frame(maxWidth: .infinity)
            .frame(height: stageHeight)
            .clipShape(RoundedRectangle(cornerRadius: stageCornerRadius, style: .continuous))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实时预览")
                    Text(vm.isRunning ? "字幕浮层正在跟随系统音频更新" : "开始捕获后会在这里同步显示转写与翻译")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)
                statusBadge
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func logPanel() -> some View {
        GroupBox {
            if hasLogOutput {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !statusFeedLines.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("运行状态")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                ForEach(Array(statusFeedLines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(14)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: nestedCornerRadius, style: .continuous))
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("字幕记录")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(groupedLogEntries) { group in
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(group.title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)

                                        ForEach(group.entries) { entry in
                                            LogEntryCard(entry: entry)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: stageCornerRadius, style: .continuous))
                .frame(minHeight: 320)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("日志将在这里显示", systemImage: "text.append")
                } description: {
                    Text("开始捕获后，这里会显示状态变化和最近的字幕记录。")
                }
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: stageCornerRadius, style: .continuous))
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("活动日志")
                    Text("查看最近的转写、翻译和运行状态变化。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Menu("导出") {
                        Button("文本日志…") {
                            vm.exportLogs()
                        }
                        .disabled(!vm.hasExportableLog)

                        Button("SRT 字幕…") {
                            vm.exportSRT()
                        }
                        .disabled(!vm.hasExportableCaptions)
                    }
                    .disabled(!vm.hasExportableLog && !vm.hasExportableCaptions)

                    Button("清空") {
                        vm.clearLogs()
                    }
                    .disabled(!hasLogOutput)
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var hasLogOutput: Bool {
        !statusFeedLines.isEmpty || !groupedLogEntries.isEmpty
    }

    private var statusFeedLines: [String] {
        let allLines = vm.logText
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("[") && !$0.hasPrefix("[进行中]") }
        return Array(allLines.suffix(6))
    }

    private var groupedLogEntries: [LogEntryGroup] {
        let calendar = Calendar.current
        let entries = Array(vm.recentEntries.suffix(24).reversed())
        var buckets: [(day: Date, entries: [CaptionEntry])] = []

        for entry in entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if let index = buckets.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: day) }) {
                buckets[index].entries.append(entry)
            } else {
                buckets.append((day: day, entries: [entry]))
            }
        }

        return buckets.map { bucket in
            LogEntryGroup(
                title: groupTitle(for: bucket.day, calendar: calendar),
                entries: bucket.entries
            )
        }
    }

    private var statusBadge: some View {
        Label(vm.isRunning ? "捕获中" : "未开始", systemImage: vm.isRunning ? "waveform.badge.mic" : "pause.circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(vm.isRunning ? Color.accentColor : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.background.secondary, in: Capsule(style: .continuous))
    }

    private func previewLines() -> [PreviewCaptionLine] {
        let currentOriginal = vm.currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentTranslated = vm.currentTranslated.trimmingCharacters(in: .whitespacesAndNewlines)

        if !currentOriginal.isEmpty || !currentTranslated.isEmpty {
            var lines: [PreviewCaptionLine] = []
            if !currentOriginal.isEmpty {
                lines.append(PreviewCaptionLine(text: currentOriginal, isTranslation: false))
            }
            if !currentTranslated.isEmpty {
                lines.append(PreviewCaptionLine(text: currentTranslated, isTranslation: true))
            }
            return lines
        }

        if let last = vm.recentEntries.last, !last.original.isEmpty || !last.translated.isEmpty {
            var lines: [PreviewCaptionLine] = []
            if !last.original.isEmpty {
                lines.append(PreviewCaptionLine(text: last.original, isTranslation: false))
            }
            if !last.translated.isEmpty {
                lines.append(PreviewCaptionLine(text: last.translated, isTranslation: true))
            }
            return lines
        }

        return [
            PreviewCaptionLine(text: "Real-time captions follow the system audio.", isTranslation: false),
            PreviewCaptionLine(text: "实时字幕会跟随系统音频更新。", isTranslation: true)
        ]
    }

    private func fittedPreviewWindowSize(in availableSize: CGSize) -> CGSize {
        let currentSize = vm.overlayPreviewSize
        let sourceWidth = Swift.max(currentSize.width, 320)
        let sourceHeight = Swift.max(currentSize.height, 80)
        let aspect = Swift.min(Swift.max(sourceWidth / sourceHeight, 2.2), 5.4)

        let maxWidth = Swift.max(availableSize.width - 40, 320)
        let maxHeight = Swift.max(availableSize.height - 32, 90)

        let widthFromHeight = maxHeight * aspect
        if widthFromHeight <= maxWidth {
            return CGSize(width: widthFromHeight, height: maxHeight)
        }

        return CGSize(width: maxWidth, height: maxWidth / aspect)
    }

    private func previewStageHeight(for availableWidth: CGFloat) -> CGFloat {
        let currentSize = vm.overlayPreviewSize
        let sourceWidth = Swift.max(currentSize.width, 320)
        let sourceHeight = Swift.max(currentSize.height, 80)
        let aspect = Swift.min(Swift.max(sourceWidth / sourceHeight, 2.2), 5.4)
        let fittedHeight = Swift.max(availableWidth, 360) / aspect
        return Swift.min(Swift.max(fittedHeight, 240), 360)
    }

    private func groupTitle(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) {
            return "今天"
        }
        if calendar.isDateInYesterday(day) {
            return "昨天"
        }

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }
}

private struct PreviewCaptionLine: Identifiable {
    let id = UUID()
    let text: String
    let isTranslation: Bool
}

private struct LogEntryGroup: Identifiable {
    let title: String
    let entries: [CaptionEntry]

    var id: String { title }
}

private struct PreviewBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.26, blue: 0.46),
                    Color(red: 0.12, green: 0.45, blue: 0.55),
                    Color(red: 0.82, green: 0.48, blue: 0.26)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 220, height: 220)
                .blur(radius: 30)
                .offset(x: -120, y: -40)

            Circle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 180, height: 180)
                .blur(radius: 28)
                .offset(x: 140, y: 56)
        }
    }
}

private struct OverlayPreviewBubble: View {
    let lines: [PreviewCaptionLine]
    let style: OverlayBackgroundStyle
    let fontSize: CGFloat
    let strength: Double
    let bubbleWidth: CGFloat

    var body: some View {
        Group {
            switch style {
            case .glass:
                NativeGlassContainer(
                    cornerRadius: 20,
                    style: .clear,
                    tintColor: nativeGlassTintColor
                ) {
                    captionTextStack
                        .padding(.horizontal, 26)
                        .padding(.vertical, 18)
                        .frame(width: bubbleWidth, alignment: .center)
                }
                .frame(width: bubbleWidth)

            case .solid:
                captionTextStack
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .frame(width: bubbleWidth, alignment: .center)
                    .background(Color.black.opacity(strength), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            case .material:
                captionTextStack
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .frame(width: bubbleWidth, alignment: .center)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .opacity(strength)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var captionTextStack: some View {
        VStack(spacing: 6) {
            ForEach(lines) { line in
                Text(line.text)
                    .font(.system(
                        size: line.isTranslation ? fontSize * 0.9 : fontSize,
                        weight: line.isTranslation ? .medium : .semibold,
                        design: .rounded
                    ))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.88)
                    .foregroundStyle(line.isTranslation ? Color.white.opacity(0.82) : Color.white)
            }
        }
        .frame(width: max(220, bubbleWidth - 52), alignment: .center)
    }

    private var nativeGlassTintColor: NSColor {
        let normalized = min(max((strength - 0.2) / 0.8, 0.0), 1.0)
        let alpha = 0.004 + (normalized * 0.02)
        return NSColor.white.withAlphaComponent(alpha)
    }
}

private struct LogEntryCard: View {
    let entry: CaptionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.timeFormatter.string(from: entry.createdAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            if !entry.original.isEmpty {
                Text(entry.original)
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !entry.translated.isEmpty {
                Text(entry.translated)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(ViewModel())
    }
}
