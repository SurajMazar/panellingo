import Foundation
import Translation

/// On-device translation with Apple's Translation framework.
///
/// Translates each region independently (the framework has no notion of dialogue context or
/// glossaries). Glossary spellings are applied afterwards. Requires the language pair to be
/// downloaded; the app offers a download flow (SwiftUI `translationTask`) when it is not.
public struct AppleTranslationProvider: TranslationProvider {
    public let configuration: ProviderConfiguration
    public var kind: ProviderKind { .apple }

    public init(configuration: ProviderConfiguration = ProviderConfiguration(kind: .apple)) {
        self.configuration = configuration
    }

    public enum PairStatus: Sendable { case installed, downloadable, unsupported }

    static func language(_ code: String) -> Locale.Language { Locale.Language(identifier: code) }

    public static func status(source: String, target: String) async -> PairStatus {
        let s = await LanguageAvailability().status(from: language(source), to: language(target))
        switch s {
        case .installed: return .installed
        case .supported: return .downloadable
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    public static func supportedLanguages() async -> [String] {
        await LanguageAvailability().supportedLanguages.map { $0.minimalIdentifier }.sorted()
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        var source = request.sourceLanguage
        if source == "auto" {
            let sample = request.items.map(\.text).joined(separator: " ")
            guard let d = TextJoiner.detectLanguage(sample) else {
                throw PanelLingoError.provider(.apple, .notConfigured("could not detect the source language; choose it explicitly"))
            }
            source = d
        }
        let status = await Self.status(source: source, target: request.targetLanguage)
        if status == .unsupported {
            throw PanelLingoError.provider(.apple, .unsupportedLanguagePair(source, request.targetLanguage))
        }
        guard #available(macOS 26.0, *) else {
            throw PanelLingoError.provider(.apple, .notConfigured("background Apple Translation requires macOS 26"))
        }
        // Always try when the pair is supported: the availability answer can lag behind a language
        // pack that was just downloaded (especially while the app is already running).
        var byID: [String: String] = [:]
        do {
            byID = try await Self.translateInstalled(request.items, source: source, target: request.targetLanguage)
        } catch is CancellationError {
            throw PanelLingoError.cancelled
        } catch {
            if status == .downloadable { throw PanelLingoError.provider(.apple, .languageNotInstalled(source, request.targetLanguage)) }
            throw PanelLingoError.provider(.apple, .server(0, error.localizedDescription))
        }
        let outputs = request.items.map { item in
            TranslationOutput(regionID: item.id, originalText: item.text,
                              translatedText: GlossaryApplier.apply(request.glossary, to: byID[item.id] ?? "", source: item.text),
                              reviewRequired: byID[item.id] == nil && !item.text.isEmpty)
        }
        return TranslationResult(outputs: outputs, provider: .apple, model: "on-device")
    }

    @available(macOS 26.0, *)
    static func translateInstalled(_ items: [TranslationItem], source: String, target: String) async throws -> [String: String] {
        let session = TranslationSession(installedSource: language(source), target: language(target))
        let reqs = items.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { TranslationSession.Request(sourceText: normalise($0.text), clientIdentifier: $0.id) }
        var byID: [String: String] = [:]
        if reqs.isEmpty { return byID }
        for r in try await session.translations(from: reqs) {
            if let id = r.clientIdentifier { byID[id] = r.targetText }
        }
        return byID
    }

    /// OCR line breaks inside a bubble are layout, not sentence breaks.
    static func normalise(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: s.containsCJK ? "" : " ")
    }

    public func listModels() async throws -> [String] { ["on-device"] }

    public func testConnection() async -> ProviderStatus {
        let langs = await Self.supportedLanguages()
        return ProviderStatus(ok: !langs.isEmpty, message: langs.isEmpty ? "Apple Translation is unavailable on this Mac."
                              : "Available — \(langs.count) languages supported on this Mac.", models: ["on-device"])
    }
}
