import Foundation
import Combine
import ScreenCaptureKit
import Speech
import QuartzCore

final class CaptureTranscriber: NSObject, ObservableObject {
    @Published var isRunning: Bool = false
    @Published var logText: String = ""
    @Published var translatedLogText: String = ""
    // 当前正在展示的一句（增量更新，不追加日志）
    @Published var currentOriginal: String = ""
    @Published var currentTranslated: String = ""
    @Published var currentCombined: String = ""
    @Published var recentEntries: [CaptionEntry] = []

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "capture.audio.queue")

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var lastTranslatedSource: String = ""
    private var lastDisplayedSentence: String = ""
    private var lastLoggedSentence: String = ""
    private var hasLoggedPartialResult: Bool = false
    private var partialUpdateTimer: Timer?
    private var translationTask: Task<Void, Never>?
    private var lastDisplayUpdate: CFTimeInterval = 0
    private let maxLogLines: Int = 200
    private let maxRecentEntries: Int = 50
    private let minDisplayInterval: CFTimeInterval = 0.15

    func start(locale: Locale = Locale.current, contentFilter: SCContentFilter? = nil) {
        guard !isRunning else { return }

        Task { [weak self] in
            guard let self else { return }

            // 1) Ask Speech permission first to fail fast
            let speechAuthorized = await Self.requestSpeechAuthorization()
            guard speechAuthorized else {
                self.appendLog("[错误] 语音识别未授权。请在系统设置 > 隐私与安全性 > 语音识别中授权。")
                return
            }

            self.setupRecognizer(locale: locale)

            // Make sure setupRecognizer was successful
            guard self.recognitionTask != nil else {
                // setupRecognizer will have already logged the error
                return
            }

            do {
                try await self.startCaptureAndTranscribe(filter: contentFilter)
                DispatchQueue.main.async { 
                    self.isRunning = true 
                    self.startPartialUpdateTimer()
                }
                self.appendLog("[信息] 已开始捕获系统音频并转写…")
            } catch {
                self.appendLog("[错误] 启动失败: \(error.localizedDescription)")
                self.stop()
            }
        }
    }

    func stop() {
        partialUpdateTimer?.invalidate()
        partialUpdateTimer = nil
        
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        translationTask?.cancel()
        translationTask = nil
        let currentStream = stream
        stream = nil
        DispatchQueue.main.async { self.isRunning = false }

        Task { [weak self] in
            guard let self else { return }
            if let stream = currentStream {
                do {
                    try await stream.stopCapture()
                } catch {
                    appendLog("[警告] 停止采集出错: \(error.localizedDescription)")
                }
            }
            appendLog("[信息] 已停止。")
        }
    }

    private func setupRecognizer(locale: Locale) {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            self.appendLog("[错误] 无法初始化语音识别器，地区 '\(locale.identifier)' 可能不受支持。")
            return
        }

        if #available(macOS 13.0, *) {
            guard recognizer.supportsOnDeviceRecognition else {
                self.appendLog("[错误] 当前语言不支持本地语音识别，请更换语言或安装离线模型。")
                return
            }
        } else {
            self.appendLog("[错误] 当前系统版本不支持本地语音识别。")
            return
        }

        if !recognizer.isAvailable {
            self.appendLog("[错误] 语音识别器当前不可用（地区: \(locale.identifier)）。请检查系统设置。")
            return
        }

        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.recognitionRequest = request

        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let error {
                let nsError = error as NSError
                // 忽略"未检测到语音"这类常见且无害的错误
                if !(nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110) {
                     self.appendLog("[错误] 识别任务: \(error.localizedDescription)")
                }
                return
            }
            guard let result else { return }

            let sentence = self.latestSentence(from: result)
            let isFinal = result.isFinal
            
            // Debug logging
            if !sentence.isEmpty {
                self.debugLog("[DEBUG] 识别结果 (isFinal: \(isFinal)): \(sentence)")
            }
            
            if !sentence.isEmpty, sentence != self.lastDisplayedSentence {
                self.lastDisplayedSentence = sentence

                if self.shouldUpdateDisplay(isFinal: isFinal) {
                    DispatchQueue.main.async { self.currentOriginal = sentence }
                    if sentence != self.lastTranslatedSource {
                        self.lastTranslatedSource = sentence
                        self.scheduleTranslation(for: sentence)
                    }
                }
            }

            if isFinal {
                self.debugLog("[DEBUG] 最终结果，准备记录到日志")
                let finalText = self.lastDisplayedSentence.isEmpty ? self.latestSentence(from: result) : self.lastDisplayedSentence
                if !finalText.isEmpty {
                    let wasPartialLogged = self.hasLoggedPartialResult
                    let entryID = self.appendRecentEntry(original: finalText)
                    
                    // If we logged a partial result and it's similar to the final result,
                    // replace it instead of appending
                    if wasPartialLogged && self.calculateSimilarity(self.lastLoggedSentence, finalText) > 0.7 {
                        self.debugLog("[DEBUG] 替换部分结果为最终结果")
                        self.replaceLastLog(finalText)
                    } else {
                        self.appendLog(finalText)
                    }
                    self.lastLoggedSentence = finalText
                    self.hasLoggedPartialResult = false
                    
                    self.translateFinal(finalText, entryID: entryID, wasPartialLogged: wasPartialLogged)
                }
                self.lastDisplayedSentence = ""
            }
        }
    }

    private func latestSentence(from result: SFSpeechRecognitionResult) -> String {
        let fullString = result.bestTranscription.formattedString
        let full = fullString as NSString
        let segments = result.bestTranscription.segments
        guard !segments.isEmpty else {
            return fullString.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let enders = CharacterSet(charactersIn: ".?!。？！…！？")
        var lastBoundaryLocation: Int = -1
        for i in 0..<(segments.count - 1) {
            let seg = segments[i]
            let segRange = seg.substringRange
            let segText = full.substring(with: segRange)
            let end = seg.timestamp + seg.duration
            let nextStart = segments[i + 1].timestamp
            let gap = nextStart - end
            if segText.unicodeScalars.last.map({ enders.contains($0) }) == true || gap >= 0.6 {
                lastBoundaryLocation = segRange.location + segRange.length
            }
        }

        if lastBoundaryLocation >= 0 {
            let tailRange = NSRange(location: lastBoundaryLocation, length: max(0, full.length - lastBoundaryLocation))
            return full.substring(with: tailRange).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback: if没有检测到句边界，取结尾的若干 segment，避免从头展示
        let maxChars = 160
        let maxSegments = 20
        var startLoc = full.length
        var charCount = 0
        var used = 0
        var idx = segments.count - 1
        while idx >= 0 && used < maxSegments && charCount < maxChars {
            let r = segments[idx].substringRange
            startLoc = r.location
            charCount += r.length
            used += 1
            idx -= 1
        }
        let len = max(0, full.length - startLoc)
        let tail = full.substring(with: NSRange(location: startLoc, length: len))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tail
    }

    private func startCaptureAndTranscribe(filter: SCContentFilter?) async throws {
        let activeFilter: SCContentFilter
        if let filter {
            activeFilter = filter
        } else {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                throw NSError(domain: "CaptureTranscriber", code: -1, userInfo: [NSLocalizedDescriptionKey: "未找到可用显示器"])
            }
            activeFilter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        // 设置最小分辨率以减少资源占用，因为我们不需要视频
        config.width = 1
        config.height = 1
        config.showsCursor = false
        // 音频配置
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        // 禁用视频捕获以避免 "stream output NOT found" 警告
        if #available(macOS 14.0, *) {
            config.captureResolution = .nominal
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 FPS (最低)
        config.queueDepth = 1

        let stream = SCStream(filter: activeFilter, configuration: config, delegate: self)
        self.stream = stream

        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
    }

    private func appendLog(_ line: String) {
        debugLog(line)
        DispatchQueue.main.async {
            self.logText = self.appendLine(line, to: self.logText)
        }
    }

    func appendUserLog(_ line: String) {
        appendLog(line)
    }

    func clearLogs() {
        DispatchQueue.main.async {
            self.logText = ""
            self.translatedLogText = ""
            self.recentEntries = []
            self.currentOriginal = ""
            self.currentTranslated = ""
            self.currentCombined = ""
            self.lastDisplayedSentence = ""
            self.lastLoggedSentence = ""
            self.lastTranslatedSource = ""
            self.hasLoggedPartialResult = false
        }
    }

    private func appendTranslation(_ line: String) {
        debugLog("译: \(line)")
        DispatchQueue.main.async {
            self.translatedLogText = self.appendLine(line, to: self.translatedLogText)
        }
    }
    
    private func replaceLastLog(_ line: String) {
        debugLog("替换日志: \(line)")
        DispatchQueue.main.async {
            // Find the last line and replace it
            if let lastNewlineIndex = self.logText.lastIndex(of: "\n") {
                let beforeLastLine = String(self.logText[...lastNewlineIndex])
                self.logText = beforeLastLine + line
            } else {
                // Only one line, replace it entirely
                self.logText = line
            }
        }
    }
    
    private func replaceLastTranslation(_ line: String) {
        debugLog("替换翻译: \(line)")
        DispatchQueue.main.async {
            // Find the last line and replace it
            if let lastNewlineIndex = self.translatedLogText.lastIndex(of: "\n") {
                let beforeLastLine = String(self.translatedLogText[...lastNewlineIndex])
                self.translatedLogText = beforeLastLine + line
            } else {
                // Only one line, replace it entirely
                self.translatedLogText = line
            }
        }
    }
    
    private func startPartialUpdateTimer() {
        // Timer to periodically log partial results, but only when there's significant change
        partialUpdateTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let current = self.currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Only log if we have new content with significant changes
            if !current.isEmpty && self.shouldLogPartialResult(current) {
                self.debugLog("[DEBUG] 定时器触发：记录部分结果（显著变化）")
                
                let wasPartialLogged = self.hasLoggedPartialResult
                
                // If we already logged a partial result, replace it; otherwise append
                if wasPartialLogged {
                    self.replaceLastLog("[进行中] \(current)")
                } else {
                    self.appendLog("[进行中] \(current)")
                }
                
                self.lastLoggedSentence = current
                self.hasLoggedPartialResult = true
                
                let translated = self.currentTranslated.trimmingCharacters(in: .whitespacesAndNewlines)
                if !translated.isEmpty {
                    if wasPartialLogged {
                        self.replaceLastTranslation(translated)
                    } else {
                        self.appendTranslation(translated)
                    }
                }
            }
        }
    }
    
    private func shouldLogPartialResult(_ current: String) -> Bool {
        // Don't log if it's the same as last logged
        if current == lastLoggedSentence {
            return false
        }
        
        // If we haven't logged anything yet, log it
        if lastLoggedSentence.isEmpty {
            return true
        }
        
        // Check if the new content is significantly different
        // Strategy: Only log if the content has grown by at least 20 characters
        // or if it's completely different (less than 50% similarity)
        let lengthDiff = current.count - lastLoggedSentence.count
        
        // If content grew significantly (more than 20 chars), log it
        if lengthDiff > 20 {
            return true
        }
        
        // If content shrank (likely a sentence boundary was detected), log it
        if lengthDiff < -10 {
            return true
        }
        
        // Check similarity - if less than 50% of the previous content is in the new content,
        // it's a different sentence
        let similarity = self.calculateSimilarity(lastLoggedSentence, current)
        if similarity < 0.5 {
            return true
        }
        
        return false
    }
    
    private func calculateSimilarity(_ str1: String, _ str2: String) -> Double {
        // Simple similarity: what percentage of str1 is contained in str2
        if str1.isEmpty || str2.isEmpty {
            return 0.0
        }
        
        let shorter = str1.count < str2.count ? str1 : str2
        let longer = str1.count < str2.count ? str2 : str1
        
        if longer.contains(shorter) {
            return Double(shorter.count) / Double(longer.count)
        }
        
        // Count matching characters
        let chars1 = Set(str1)
        let chars2 = Set(str2)
        let intersection = chars1.intersection(chars2)
        let union = chars1.union(chars2)
        
        return Double(intersection.count) / Double(union.count)
    }

    private func shouldUpdateDisplay(isFinal: Bool) -> Bool {
        if isFinal {
            return true
        }
        let now = CACurrentMediaTime()
        if now - lastDisplayUpdate >= minDisplayInterval {
            lastDisplayUpdate = now
            return true
        }
        return false
    }

    private func scheduleTranslation(for text: String) {
        translationTask?.cancel()
        translationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            let cn = await TranslationService.shared.translate(text)
            guard !Task.isCancelled else { return }
            DispatchQueue.main.async {
                self.currentTranslated = cn
                let original = self.currentOriginal
                if !original.isEmpty || !cn.isEmpty {
                    self.currentCombined = original.isEmpty ? "译: \(cn)" : (cn.isEmpty ? original : "\(original)\n译: \(cn)")
                } else {
                    self.currentCombined = ""
                }
            }
        }
    }

    private func translateFinal(_ text: String, entryID: UUID, wasPartialLogged: Bool) {
        translationTask?.cancel()
        translationTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let cn = await TranslationService.shared.translate(text)
            guard !Task.isCancelled else { return }
            DispatchQueue.main.async {
                if !cn.isEmpty {
                    self.updateRecentEntry(id: entryID, translated: cn)
                    if wasPartialLogged {
                        self.replaceLastTranslation(cn)
                    } else {
                        self.appendTranslation(cn)
                    }
                }
                self.currentTranslated = cn
                let original = self.currentOriginal
                if !original.isEmpty || !cn.isEmpty {
                    self.currentCombined = original.isEmpty ? "译: \(cn)" : (cn.isEmpty ? original : "\(original)\n译: \(cn)")
                } else {
                    self.currentCombined = ""
                }
            }
        }
    }

    private func appendLine(_ line: String, to text: String) -> String {
        let combined = text.isEmpty ? line : text + "\n" + line
        let lines = combined.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= maxLogLines {
            return combined
        }
        return lines.suffix(maxLogLines).joined(separator: "\n")
    }

    private func appendRecentEntry(original: String) -> UUID {
        let entry = CaptionEntry(original: original)
        DispatchQueue.main.async {
            self.recentEntries.append(entry)
            if self.recentEntries.count > self.maxRecentEntries {
                self.recentEntries.removeFirst(self.recentEntries.count - self.maxRecentEntries)
            }
        }
        return entry.id
    }

    private func updateRecentEntry(id: UUID, translated: String) {
        DispatchQueue.main.async {
            guard let index = self.recentEntries.firstIndex(where: { $0.id == id }) else { return }
            self.recentEntries[index].translated = translated
        }
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print(message)
        #endif
    }

    private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

// MARK: - SCStreamOutput / SCStreamDelegate

extension CaptureTranscriber: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, let request = recognitionRequest else { return }
        request.appendAudioSampleBuffer(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            if self.isRunning {
                self.appendLog("[错误] 音频流意外停止: \(error.localizedDescription)")
                self.stop()
            }
        }
    }
}
