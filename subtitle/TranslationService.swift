import Foundation
import NaturalLanguage

#if canImport(Translation)
import Translation
#endif

actor TranslationService {
    static let shared = TranslationService()

    #if canImport(Translation)
    @available(macOS 15.0, *)
    private struct LanguagePair: Hashable {
        let sourceIdentifier: String
        let targetIdentifier: String

        var requiresTranslation: Bool {
            sourceIdentifier != targetIdentifier
        }
    }

    @available(macOS 15.0, *)
    private let availability = LanguageAvailability()

    @available(macOS 15.0, *)
    private var preparedSessions: [LanguagePair: TranslationSession] = [:]
    #endif

    // 准备：源语言(sourceIdentifier) -> 目标语言(targetIdentifier)
    func prepare(sourceIdentifier: String, targetIdentifier: String) async {
        #if canImport(Translation)
        guard #available(macOS 15.0, *) else { return }
        let pair = LanguagePair(sourceIdentifier: sourceIdentifier, targetIdentifier: targetIdentifier)
        _ = await session(for: pair)
        #endif
    }

    func translate(_ text: String, sourceIdentifier: String, targetIdentifier: String) async -> String {
        // Respect cancellation early to avoid queuing stale translation work
        if Task.isCancelled { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        #if canImport(Translation)
        guard #available(macOS 15.0, *) else { return text }
        let pair = LanguagePair(sourceIdentifier: sourceIdentifier, targetIdentifier: targetIdentifier)
        if !pair.requiresTranslation {
            return trimmed
        }
        do {
            try Task.checkCancellation()
            guard let session = await session(for: pair) else { return text }
            let units = translationUnits(for: trimmed, sourceIdentifier: sourceIdentifier)
            let responseText: String
            if units.count <= 1 {
                let response = try await session.translate(trimmed)
                responseText = response.targetText
            } else {
                var translatedUnits: [String] = []
                translatedUnits.reserveCapacity(units.count)
                for unit in units {
                    try Task.checkCancellation()
                    let response = try await session.translate(unit)
                    translatedUnits.append(response.targetText)
                }
                responseText = translatedUnits.joined(separator: "\n")
            }
            try Task.checkCancellation()
            return responseText
        } catch is CancellationError {
            return ""
        } catch {
            print("[Translation] translate error: \(error)")
            return text
        }
        #else
        return text
        #endif
    }

    #if canImport(Translation)
    @available(macOS 15.0, *)
    private func session(for pair: LanguagePair) async -> TranslationSession? {
        if let cachedSession = preparedSessions[pair] {
            return cachedSession
        }

        let source = Locale.Language(identifier: pair.sourceIdentifier)
        let target = Locale.Language(identifier: pair.targetIdentifier)

        let status = await availability.status(from: source, to: target)
        if case .unsupported = status {
            print("[Translation] Unsupported pair: \(pair.sourceIdentifier)->\(pair.targetIdentifier)")
            return nil
        }

        do {
            let preparedSession = TranslationSession(installedSource: source, target: target)
            try await preparedSession.prepareTranslation()
            preparedSessions[pair] = preparedSession
            return preparedSession
        } catch {
            print("[Translation] prepare error: \(error)")
            return nil
        }
    }
    #endif

    private func translationUnits(for text: String, sourceIdentifier: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        if let language = tokenizerLanguage(for: sourceIdentifier) {
            tokenizer.setLanguage(language)
        }

        var units: [String] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let segment = trimmed[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                units.append(segment)
            }
            return true
        }

        return units.count > 1 ? units : [trimmed]
    }

    private func tokenizerLanguage(for sourceIdentifier: String) -> NLLanguage? {
        switch sourceIdentifier {
        case "en":
            return .english
        case "ja":
            return .japanese
        case "zh-Hans", "zh-CN":
            return .simplifiedChinese
        case "zh-Hant", "zh-TW":
            return .traditionalChinese
        case "ko":
            return .korean
        case "fr":
            return .french
        case "de":
            return .german
        case "es":
            return .spanish
        case "ru":
            return .russian
        case "it":
            return .italian
        case "pt":
            return .portuguese
        default:
            return nil
        }
    }
}
