import Foundation
import Combine
import ScreenCaptureKit
import Speech
import AVFoundation
import QuartzCore

@available(macOS 26.0, *)
final class ModernCaptureTranscriber: NSObject, ObservableObject {
    @Published var isRunning: Bool = false
    @Published var logText: String = ""
    @Published var translatedLogText: String = ""
    @Published var currentOriginal: String = ""
    @Published var currentTranslated: String = ""
    @Published var currentCombined: String = ""
    @Published var recentEntries: [CaptionEntry] = []

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "capture.audio.queue")

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var audioContinuation: AsyncStream<AnalyzerInput>.Continuation?
    
    // 音频转换相关
    private var audioConverter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    private var analysisTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    
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
    
    // 音频格式
    private var audioFormat: AVAudioFormat?

    func start(locale: Locale = Locale.current, contentFilter: SCContentFilter? = nil) {
        guard !isRunning else { return }

        Task { [weak self] in
            guard let self else { return }

            // 1) 请求语音识别权限
            let speechAuthorized = await Self.requestSpeechAuthorization()
            guard speechAuthorized else {
                await MainActor.run {
                    self.appendLog("[错误] 语音识别未授权。请在系统设置 > 隐私与安全性 > 语音识别中授权。")
                }
                return
            }

            do {
                try await self.setupAnalyzer(locale: locale)
                try await self.startCaptureAndTranscribe(filter: contentFilter)
                await MainActor.run {
                    self.isRunning = true
                    self.startPartialUpdateTimer()
                    self.appendLog("[信息] 已开始捕获系统音频并转写（使用新 SpeechAnalyzer API）…")
                }
            } catch {
                await MainActor.run {
                    self.appendLog("[错误] 启动失败: \(error.localizedDescription)")
                }
                self.stop()
            }
        }
    }

    func stop() {
        partialUpdateTimer?.invalidate()
        partialUpdateTimer = nil
        
        // 结束音频流
        audioContinuation?.finish()
        audioContinuation = nil
        
        // 取消任务
        analysisTask?.cancel()
        transcriptionTask?.cancel()
        analysisTask = nil
        transcriptionTask = nil
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
                    await MainActor.run {
                        self.appendLog("[警告] 停止采集出错: \(error.localizedDescription)")
                    }
                }
            }
            self.analyzer = nil
            self.transcriber = nil
            await MainActor.run {
                self.appendLog("[信息] 已停止。")
            }
        }
    }

    private func setupAnalyzer(locale: Locale) async throws {
        debugLog("[DEBUG] 设置 SpeechAnalyzer，语言: \(locale.identifier)")
        
        // 创建 SpeechTranscriber 模块
        // 使用 .progressiveTranscription，适合实时音频，包含部分结果
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber
        
        // 创建 SpeechAnalyzer，传入 modules
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        
        // 创建音频输入流
        let (audioStream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.audioContinuation = continuation
        
        // 启动分析任务
        analysisTask = Task { [weak self] in
            guard let self, let analyzer = self.analyzer else { return }
            do {
                // analyzeSequence 返回可等待的结果，这里只需触发分析流程
                _ = try await analyzer.analyzeSequence(audioStream)
            } catch {
                if !Task.isCancelled {
                    self.debugLog("[ERROR] 分析任务错误: \(error)")
                }
            }
        }
        
        // 启动转录处理任务
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let transcriber = self.transcriber else { return }
                // 尝试 .results
                for try await result in transcriber.results {
                    await MainActor.run {
                        self.handleTranscriptionResult(result)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.debugLog("[ERROR] 转录任务错误: \(error)")
                    await MainActor.run {
                        self.appendLog("[错误] 转录任务: \(error.localizedDescription)")
                    }
                }
            }
        }
        
        debugLog("[DEBUG] SpeechAnalyzer 设置完成")
    }
    
    @MainActor
    private func handleTranscriptionResult(_ result: SpeechTranscriber.Result) {
        var sentence = ""
        
        // 使用 Mirror 反射来绕过编译时类型检查，动态获取 alternatives
        let mirror = Mirror(reflecting: result)
        if let alternatives = mirror.children.first(where: { $0.label == "alternatives" })?.value {
            let altsMirror = Mirror(reflecting: alternatives)
            if let firstAlt = altsMirror.children.first?.value {
                if let attrStr = firstAlt as? Foundation.AttributedString {
                    // 尝试通过 characters view 获取字符串，规避 .string 属性可能的问题
                    sentence = String(attrStr.characters)
                } else if let str = firstAlt as? String {
                    sentence = str
                } else {
                    debugLog("[DEBUG] Alternative type: \(type(of: firstAlt))")
                    // 尝试从 description 中提取文本（如果它是 AttributedString 但 cast 失败，或者其他类型）
                    let desc = String(describing: firstAlt)
                    // 简单的清理逻辑，如果需要的话
                    sentence = desc
                }
            }
        }
        
        if sentence.isEmpty {
             sentence = String(describing: result)
        }
        
        let isFinal = result.isFinal
        
        // Debug logging
        if !sentence.isEmpty {
            debugLog("[DEBUG] 识别结果 (isFinal: \(isFinal)): \(sentence)")
        }
        
        if !sentence.isEmpty, sentence != self.lastDisplayedSentence {
            self.lastDisplayedSentence = sentence

            if shouldUpdateDisplay(isFinal: isFinal) {
                self.currentOriginal = sentence
                if sentence != self.lastTranslatedSource {
                    self.lastTranslatedSource = sentence
                    scheduleTranslation(for: sentence)
                }
            }
        }

        if isFinal {
            debugLog("[DEBUG] 最终结果，准备记录到日志")
            let finalText = self.lastDisplayedSentence.isEmpty ? sentence : self.lastDisplayedSentence
            if !finalText.isEmpty {
                let wasPartialLogged = self.hasLoggedPartialResult
                let entryID = self.appendRecentEntry(original: finalText)
                
                // 如果记录了部分结果且与最终结果相似，则替换
                if wasPartialLogged && self.calculateSimilarity(self.lastLoggedSentence, finalText) > 0.7 {
                    debugLog("[DEBUG] 替换部分结果为最终结果")
                    self.replaceLastLog(finalText)
                } else {
                    self.appendLog(finalText)
                }
                self.lastLoggedSentence = finalText
                self.hasLoggedPartialResult = false
                
                translateFinal(finalText, entryID: entryID, wasPartialLogged: wasPartialLogged)
            }
            self.lastDisplayedSentence = ""
        }
    }

    private func startCaptureAndTranscribe(filter: SCContentFilter?) async throws {
        let activeFilter: SCContentFilter
        if let filter {
            activeFilter = filter
        } else {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                throw NSError(domain: "ModernCaptureTranscriber", code: -1, userInfo: [NSLocalizedDescriptionKey: "未找到可用显示器"])
            }
            debugLog("[DEBUG] 使用显示器: \(display.width)x\(display.height) ID:\(display.displayID)")

            // 明确排除当前应用
            let excludedApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            activeFilter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        // 增加尺寸，避免潜在的驱动问题
        config.width = 100
        config.height = 100
        config.showsCursor = false
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        config.captureResolution = .nominal
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5 // 稍微增加队列深度
        
        let stream = SCStream(filter: activeFilter, configuration: config, delegate: self)
        self.stream = stream

        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
    }
    
    // MARK: - 音频格式转换
    
    private func convertToAVAudioPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            debugLog("[ERROR] 无法获取音频格式描述")
            return nil
        }
        
        guard let streamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            debugLog("[ERROR] 无法获取音频流基本描述")
            return nil
        }
        
        var description = streamBasicDescription.pointee
        guard let format = AVAudioFormat(streamDescription: &description) else {
            debugLog("[ERROR] 无法创建 AVAudioFormat")
            return nil
        }
        
        if audioFormat == nil {
            audioFormat = format
            debugLog("[DEBUG] 音频格式: \(format)")
        }
        
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            debugLog("[ERROR] 无法获取数据缓冲区")
            return nil
        }
        
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        
        guard status == kCMBlockBufferNoErr, let dataPointer else {
            debugLog("[ERROR] 无法获取数据指针")
            return nil
        }
        
        let bytesPerFrame = Int(description.mBytesPerFrame)
        guard bytesPerFrame > 0 else {
            debugLog("[ERROR] 无法计算帧大小")
            return nil
        }
        
        let frameCount = AVAudioFrameCount(length / bytesPerFrame)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            debugLog("[ERROR] 无法创建 PCM 缓冲区")
            return nil
        }
        
        pcmBuffer.frameLength = frameCount
        
        let audioBufferList = pcmBuffer.mutableAudioBufferList
        let buffer = audioBufferList.pointee.mBuffers
        guard let mData = buffer.mData else {
            debugLog("[ERROR] PCM 缓冲区无数据指针")
            return nil
        }
        
        let copySize = min(Int(buffer.mDataByteSize), length)
        memcpy(mData, dataPointer, copySize)
        
        return pcmBuffer
    }

    // MARK: - 日志管理
    
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
            if let lastNewlineIndex = self.logText.lastIndex(of: "\n") {
                let beforeLastLine = String(self.logText[...lastNewlineIndex])
                self.logText = beforeLastLine + line
            } else {
                self.logText = line
            }
        }
    }
    
    private func replaceLastTranslation(_ line: String) {
        debugLog("替换翻译: \(line)")
        DispatchQueue.main.async {
            if let lastNewlineIndex = self.translatedLogText.lastIndex(of: "\n") {
                let beforeLastLine = String(self.translatedLogText[...lastNewlineIndex])
                self.translatedLogText = beforeLastLine + line
            } else {
                self.translatedLogText = line
            }
        }
    }
    
    // MARK: - 部分结果管理
    
    private func startPartialUpdateTimer() {
        partialUpdateTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let current = self.currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !current.isEmpty && self.shouldLogPartialResult(current) {
                debugLog("[DEBUG] 定时器触发：记录部分结果（显著变化）")
                
                let wasPartialLogged = self.hasLoggedPartialResult
                
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
        if current == lastLoggedSentence {
            return false
        }
        
        if lastLoggedSentence.isEmpty {
            return true
        }
        
        let lengthDiff = current.count - lastLoggedSentence.count
        
        if lengthDiff > 20 {
            return true
        }
        
        if lengthDiff < -10 {
            return true
        }
        
        let similarity = self.calculateSimilarity(lastLoggedSentence, current)
        if similarity < 0.5 {
            return true
        }
        
        return false
    }
    
    private func calculateSimilarity(_ str1: String, _ str2: String) -> Double {
        if str1.isEmpty || str2.isEmpty {
            return 0.0
        }
        
        let shorter = str1.count < str2.count ? str1 : str2
        let longer = str1.count < str2.count ? str2 : str1
        
        if longer.contains(shorter) {
            return Double(shorter.count) / Double(longer.count)
        }
        
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
            await MainActor.run {
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
            await MainActor.run {
                self.updateRecentEntry(id: entryID, translated: cn)
                if wasPartialLogged {
                    self.replaceLastTranslation(cn)
                } else {
                    self.appendTranslation(cn)
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

@available(macOS 26.0, *)
extension ModernCaptureTranscriber: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        
        // 转换为 AVAudioPCMBuffer (原始 Float32)
        guard let inputBuffer = convertToAVAudioPCMBuffer(sampleBuffer) else {
            return
        }
        
        // 初始化转换器
        if audioConverter == nil {
            audioConverter = AVAudioConverter(from: inputBuffer.format, to: targetFormat)
        }
        
        guard let converter = audioConverter else { return }
        
        // 计算输出帧数
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }
        
        var error: NSError?
        var handled = false
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if !handled {
                handled = true
                outStatus.pointee = .haveData
                return inputBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if status != .error, error == nil {
            // 发送到 SpeechAnalyzer
            audioContinuation?.yield(AnalyzerInput(buffer: outputBuffer))
        } else {
            debugLog("[ERROR] 音频转换失败: \(error?.localizedDescription ?? "未知错误")")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            if self.isRunning {
                self.appendLog("[错误] 音频流意外停止: \(error.localizedDescription)")
                self.stop()
            }
        }
    }
}
