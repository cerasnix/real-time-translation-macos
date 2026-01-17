import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor
final class ViewModel: ObservableObject {
    @Published var localeIdentifier: String = Locale.current.identifier
    @Published var autoScroll: Bool = true
    @Published var translationSource: String = "en" {
        didSet {
            let mapped = Self.mapToSpeechLocale(from: translationSource)
            localeIdentifier = mapped
            Task { await TranslationService.shared.prepare(sourceIdentifier: translationSource, targetIdentifier: translationTarget) }
            if isRunning {
                stop()
                start()
            }
        }
    }
    @Published var translationTarget: String = "zh-Hans" {
        didSet {
            Task { await TranslationService.shared.prepare(sourceIdentifier: translationSource, targetIdentifier: translationTarget) }
            if isRunning {
                stop()
                start()
            }
        }
    }
    
    @Published var maxLines: Int = 2 {
        didSet {
            OverlayWindowController.shared.updateMaxLines(maxLines)
        }
    }
    
    @Published var fontSize: CGFloat = 28 {
        didSet {
            OverlayWindowController.shared.updateFontSize(fontSize)
        }
    }

    @Published var backgroundOpacity: Double = 0.65 {
        didSet {
            OverlayWindowController.shared.updateBackgroundOpacity(backgroundOpacity)
        }
    }

    @Published var backgroundStyle: OverlayBackgroundStyle = .solid {
        didSet {
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

    init() {
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
        
        // 初始化 localeIdentifier，确保它与默认的 translationSource 匹配
        // 否则它会使用系统 locale (例如 en_JP)，这可能不被语音识别支持
        localeIdentifier = Self.mapToSpeechLocale(from: translationSource)
    }

    func start() {
        let locale = Locale(identifier: localeIdentifier)
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
}

struct ContentView: View {
    @EnvironmentObject private var vm: ViewModel

    var body: some View {
        GlassEffectContainer {
            GeometryReader { proxy in
                let isCompact = proxy.size.width < 980

                VStack(spacing: 20) {
                    headerView()

                    if isCompact {
                        VStack(spacing: 20) {
                            settingsPanel()
                            logPanel()
                        }
                    } else {
                        HStack(alignment: .top, spacing: 20) {
                            settingsPanel()
                                .frame(width: min(max(340, proxy.size.width * 0.36), 480))
                                .frame(maxHeight: .infinity)
                            logPanel()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .layoutPriority(1)
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
    }

    private func headerView() -> some View {
        GlassCard {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Subtitle")
                        .font(.system(.title, design: .rounded).weight(.semibold))
                    Text("系统音频字幕与本地翻译")
                        .foregroundStyle(.secondary)
                        .font(.system(.callout, design: .rounded))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        vm.toggle()
                    } label: {
                        Label(vm.isRunning ? "停止" : "开始", systemImage: vm.isRunning ? "stop.circle.fill" : "play.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(vm.isRunning ? .red : .accentColor)
                    .keyboardShortcut(.space, modifiers: [])

                    HStack(spacing: 6) {
                        Image(systemName: "command")
                        Text("Shift+Space 全局切换")
                    }
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
            }
        }
    }

    private func settingsPanel() -> some View {
        GlassCard {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("设置")
                        .font(.headline)

                    settingsSection("语言") {
                        Grid(horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                rowLabel("源语言")
                                Picker("源语言", selection: $vm.translationSource) {
                                    Text("英语 (English)").tag("en")
                                    Text("日语 (日本語)").tag("ja")
                                    Text("中文 (简体)").tag("zh-Hans")
                                    Text("中文 (繁体)").tag("zh-Hant")
                                    Text("韩语 (한국어)").tag("ko")
                                    Text("法语 (Français)").tag("fr")
                                    Text("德语 (Deutsch)").tag("de")
                                    Text("西班牙语 (Español)").tag("es")
                                    Text("俄语 (Русский)").tag("ru")
                                    Text("意大利语 (Italiano)").tag("it")
                                    Text("葡萄牙语 (Português)").tag("pt")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            GridRow {
                                rowLabel("目标语言")
                                Picker("目标语言", selection: $vm.translationTarget) {
                                    Text("中文 (简体)").tag("zh-Hans")
                                    Text("中文 (繁体)").tag("zh-Hant")
                                    Text("英语").tag("en")
                                    Text("日语").tag("ja")
                                    Text("韩语").tag("ko")
                                    Text("法语").tag("fr")
                                    Text("德语").tag("de")
                                    Text("西班牙语").tag("es")
                                    Text("俄语").tag("ru")
                                    Text("意大利语").tag("it")
                                    Text("葡萄牙语").tag("pt")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    settingsSection("显示") {
                        Grid(horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                rowLabel("条数")
                                Stepper("\(vm.maxLines)", value: $vm.maxLines, in: 1...10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            GridRow {
                                rowLabel("字体")
                                Stepper("\(Int(vm.fontSize))", value: $vm.fontSize, in: 12...48, step: 2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    settingsSection("外观") {
                        Grid(horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                rowLabel("风格")
                                Picker("风格", selection: $vm.backgroundStyle) {
                                    ForEach(OverlayBackgroundStyle.allCases) { style in
                                        Text(style.rawValue).tag(style)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }

                            GridRow {
                                rowLabel("透明度")
                                HStack(spacing: 8) {
                                    Slider(value: $vm.backgroundOpacity, in: 0.2...1.0)
                                    Text("\(Int(vm.backgroundOpacity * 100))%")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 40, alignment: .trailing)
                                }
                            }
                        }
                    }

                    settingsSection("行为") {
                        Toggle("自动滚动", isOn: $vm.autoScroll)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func logPanel() -> some View {
        MaterialCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("日志")
                        .font(.headline)
                    Spacer()
                    HStack(spacing: 8) {
                        Button("清空") {
                            vm.clearLogs()
                        }
                        Button("保存…") {
                            saveLogs()
                        }
                        if vm.isRunning {
                            Label("进行中", systemImage: "dot.radiowaves.left.and.right")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(combinedDisplayText())
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id("bottom")
                        }
                        .padding(8)
                    }
                    .onChange(of: vm.logText) {
                        guard vm.autoScroll else { return }
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .onChange(of: vm.recentEntries) {
                        guard vm.autoScroll else { return }
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func settingsSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func combinedDisplayText() -> String {
        let statusLines = vm.logText
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("[") && !$0.hasPrefix("[进行中]") }
        let entries = vm.recentEntries

        if statusLines.isEmpty && entries.isEmpty {
            return "日志输出将显示在这里…\n首次使用会请求‘屏幕录制’和‘语音识别’权限。"
        }

        var result = ""

        let maxStatusEntries = 8
        if !statusLines.isEmpty {
            let start = max(0, statusLines.count - maxStatusEntries)
            for line in statusLines[start...] {
                result += line + "\n"
            }
            result += "\n"
        }

        let maxLogEntries = 50
        let start = max(0, entries.count - maxLogEntries)
        for entry in entries[start...] {
            if !entry.original.isEmpty {
                result += entry.original + "\n"
            }
            if !entry.translated.isEmpty {
                result += "译: " + entry.translated + "\n"
            }
            result += "\n"
        }

        return result
    }

    @MainActor
    private func saveLogs() {
        let content = vm.exportLogText()
        guard !content.isEmpty else {
            vm.logUserMessage("[提示] 当前没有可保存的日志。")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.nameFieldStringValue = "subtitle-log.txt"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    vm.logUserMessage("[信息] 日志已保存: \(url.lastPathComponent)")
                } catch {
                    vm.logUserMessage("[错误] 保存日志失败: \(error.localizedDescription)")
                }
            }
        }
    }
}

private func rowLabel(_ text: String) -> some View {
    Text(text)
        .foregroundStyle(.secondary)
        .frame(width: 70, alignment: .leading)
}

private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(18)
            .glassEffect(in: RoundedRectangle(cornerRadius: 18))
            .tint(Color.white.opacity(0.12))
    }
}

private struct MaterialCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

#Preview {
    ContentView()
        .environmentObject(ViewModel())
}
