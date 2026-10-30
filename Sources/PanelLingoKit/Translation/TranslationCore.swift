import Foundation

public struct TranslationItem: Codable, Hashable, Sendable {
    public var id: String
    public var text: String
    public var kind: String
    public init(id: String, text: String, kind: String = "speech") { self.id = id; self.text = text; self.kind = kind }
}

public struct ContextLine: Codable, Hashable, Sendable {
    public var source: String
    public var translation: String?
    public init(source: String, translation: String?) { self.source = source; self.translation = translation }
}

public struct TranslationRequest: Sendable {
    public var sourceLanguage: String
    public var targetLanguage: String
    /// Regions to translate, in reading order.
    public var items: [TranslationItem]
    /// Dialogue from the previous page (already translated when available).
    public var previousContext: [ContextLine] = []
    /// Other dialogue on this page that is not being translated in this request.
    public var nearbyContext: [ContextLine] = []
    public var glossary: [GlossaryEntry] = []
    public var tone: TranslationTone = .natural
    public var honorifics: HonorificPolicy = .preserve
    public var customInstructions: String = ""
    public var storyContext: String = ""
    /// JPEG page image, only populated when the user allows sending images.
    public var pageImageJPEG: Data?

    public init(sourceLanguage: String, targetLanguage: String, items: [TranslationItem]) {
        self.sourceLanguage = sourceLanguage; self.targetLanguage = targetLanguage; self.items = items
    }

    public var characterCount: Int { items.reduce(0) { $0 + $1.text.count } }
}

public struct TranslationOutput: Codable, Hashable, Sendable {
    public var regionID: String
    public var originalText: String
    public var translatedText: String
    public var confidence: Double?
    public var reviewRequired: Bool
    public var notes: String?
    public init(regionID: String, originalText: String, translatedText: String, confidence: Double? = nil,
                reviewRequired: Bool = false, notes: String? = nil) {
        self.regionID = regionID; self.originalText = originalText; self.translatedText = translatedText
        self.confidence = confidence; self.reviewRequired = reviewRequired; self.notes = notes
    }
}

public struct TranslationResult: Sendable {
    public var outputs: [TranslationOutput]
    public var provider: ProviderKind
    public var model: String?
    public init(outputs: [TranslationOutput], provider: ProviderKind, model: String?) {
        self.outputs = outputs; self.provider = provider; self.model = model
    }
}

public struct ProviderStatus: Sendable {
    public var ok: Bool
    public var message: String
    public var models: [String]
    public init(ok: Bool, message: String, models: [String] = []) { self.ok = ok; self.message = message; self.models = models }
}

public protocol TranslationProvider: Sendable {
    var kind: ProviderKind { get }
    var configuration: ProviderConfiguration { get }
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
    func listModels() async throws -> [String]
    func testConnection() async -> ProviderStatus
}

// MARK: - Prompting

public enum TranslationPrompt {
    public static let system = """
    You are an expert professional comic, manga, manhwa, and webtoon translator and localization editor.

    Translate the supplied dialogue from the specified source language into the specified target language.

    You are given multiple text regions in comic reading order and may receive neighboring dialogue, character context, and a terminology glossary.

    Produce dialogue that sounds fluent, natural, emotionally accurate, and appropriate for the characters.

    Preserve meaning and tone. Avoid awkward literal translations. Preserve jokes, wordplay, sarcasm, and character personalities wherever possible.

    Keep established character names, preferred spellings, and terminology consistent.

    Follow the requested honorific and localization preferences.

    Do not invent story details or add dialogue that is absent from the source.

    Do not silently omit meaningful lines.

    Keep the translated text concise enough for the original speech bubbles where possible, but do not sacrifice essential meaning for brevity.

    When the source is ambiguous, prioritize context and clearly flag low-confidence interpretation.

    Return strictly structured results using the original stable text-region IDs. Never modify, merge, or reorder IDs.

    Do not include explanations in the translated dialogue field.
    """

    public static let outputContract = """
    Respond with ONLY a JSON object of this exact shape (no markdown, no commentary):
    {"translations":[{"region_id":"<id from input>","original_text":"<source>","translated_text":"<translation>","confidence":0.0,"review_required":false,"notes":null}]}
    Include exactly one entry for every input region_id. "confidence" is your own 0–1 estimate. Set "review_required" to true and explain in "notes" when the source is ambiguous, garbled (likely OCR error) or needs a human decision.
    """

    public static func userMessage(_ r: TranslationRequest) -> String {
        var s = "Source language: \(LanguageInfo.name(r.sourceLanguage)) (\(r.sourceLanguage))\n"
        s += "Target language: \(LanguageInfo.name(r.targetLanguage)) (\(r.targetLanguage))\n"
        if !r.tone.instruction.isEmpty { s += "Style: \(r.tone.displayName). \(r.tone.instruction)\n" }
        switch r.honorifics {
        case .preserve: s += "Honorifics: keep Japanese/Korean honorifics attached to names (e.g. Subaru-kun, senpai, oppa).\n"
        case .localize: s += "Honorifics: replace honorifics with natural target-language equivalents (titles, nicknames, tone).\n"
        case .drop: s += "Honorifics: drop honorifics; convey politeness through phrasing instead.\n"
        }
        if !r.storyContext.isEmpty { s += "\nStory / character context:\n\(r.storyContext)\n" }
        if !r.customInstructions.isEmpty { s += "\nAdditional instructions from the user:\n\(r.customInstructions)\n" }
        let relevant = r.glossary.filter { g in r.items.contains { g.matches($0.text) } || g.isCharacterName }
        if !relevant.isEmpty {
            s += "\nGlossary (always use the preferred rendering):\n"
            for g in relevant {
                var line = "- \(g.original) → \(g.preferred)"
                if !g.alternatives.isEmpty { line += " (also written: \(g.alternatives.joined(separator: ", ")))" }
                if g.isCharacterName { line += " [character name]" }
                if !g.honorificRule.isEmpty { line += " — honorifics: \(g.honorificRule)" }
                if !g.notes.isEmpty { line += " — \(g.notes)" }
                s += line + "\n"
            }
        }
        if !r.previousContext.isEmpty {
            s += "\nPrevious page dialogue (context only, do not translate):\n"
            for c in r.previousContext.suffix(20) { s += "- \(c.source)" + (c.translation.map { " → \($0)" } ?? "") + "\n" }
        }
        if !r.nearbyContext.isEmpty {
            s += "\nOther dialogue on this page (context only, do not translate):\n"
            for c in r.nearbyContext { s += "- \(c.source)" + (c.translation.map { " → \($0)" } ?? "") + "\n" }
        }
        let items = r.items.map { ["region_id": $0.id, "type": $0.kind, "text": $0.text] }
        let json = (try? JSONSerialization.data(withJSONObject: ["regions": items], options: [.prettyPrinted, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        s += "\nRegions to translate, in reading order:\n\(json)\n\n\(outputContract)"
        return s
    }

    /// JSON Schema for providers with structured-output support.
    public static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "translations": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "region_id": ["type": "string"],
                            "original_text": ["type": "string"],
                            "translated_text": ["type": "string"],
                            "confidence": ["type": "number"],
                            "review_required": ["type": "boolean"],
                            "notes": ["type": ["string", "null"]],
                        ],
                        "required": ["region_id", "original_text", "translated_text", "confidence", "review_required", "notes"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["translations"],
            "additionalProperties": false,
        ]
    }
}

// MARK: - Validation

public enum TranslationResponseParser {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noJSON
        case invalidJSON(String)
        case unknownID(String)
        case duplicateID(String)
        case missingIDs([String])
        case emptyTranslation(String)
        public var description: String {
            switch self {
            case .noJSON: "no JSON object found"
            case .invalidJSON(let s): "invalid JSON: \(s)"
            case .unknownID(let s): "unknown region_id \(s)"
            case .duplicateID(let s): "duplicate region_id \(s)"
            case .missingIDs(let s): "missing region_id(s): \(s.joined(separator: ", "))"
            case .emptyTranslation(let s): "empty translation for \(s)"
            }
        }
    }

    struct Envelope: Decodable { var translations: [Entry] }
    struct Entry: Decodable {
        var region_id: String
        var original_text: String?
        var translated_text: String
        var confidence: Double?
        var review_required: Bool?
        var notes: String?
    }

    /// Extracts the outermost JSON object from model output (tolerates code fences / chatter).
    public static func extractJSON(_ text: String) -> String? {
        var t = text
        if let think = t.range(of: "</think>") { t = String(t[think.upperBound...]) }
        guard let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end else { return nil }
        return String(t[start...end])
    }

    /// Parses and validates. Returns valid outputs plus the IDs that are still missing.
    public static func parse(_ text: String, request: TranslationRequest, allowPartial: Bool = true) throws -> (outputs: [TranslationOutput], missing: [String]) {
        guard let json = extractJSON(text) else { throw Failure.noJSON }
        let env: Envelope
        do { env = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)) } catch {
            // Some models return a bare array under a different key; try the first array of objects.
            if let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
               let arr = obj.values.first(where: { $0 is [[String: Any]] }),
               let data = try? JSONSerialization.data(withJSONObject: ["translations": arr]),
               let e = try? JSONDecoder().decode(Envelope.self, from: data) {
                env = e
            } else { throw Failure.invalidJSON(String(describing: error).prefix(160).description) }
        }
        let byID = Dictionary(uniqueKeysWithValues: request.items.map { ($0.id, $0) })
        var seen = Set<String>()
        var outputs: [TranslationOutput] = []
        for e in env.translations {
            let id = e.region_id.trimmingCharacters(in: .whitespaces)
            guard let item = byID[id] else { throw Failure.unknownID(id) }
            guard seen.insert(id).inserted else { throw Failure.duplicateID(id) }
            let translated = e.translated_text.trimmingCharacters(in: .whitespacesAndNewlines)
            if translated.isEmpty && !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw Failure.emptyTranslation(id)
            }
            outputs.append(TranslationOutput(regionID: id, originalText: item.text, translatedText: translated,
                                             confidence: e.confidence.map { min(1, max(0, $0)) },
                                             reviewRequired: e.review_required ?? false,
                                             notes: e.notes?.isEmpty == true ? nil : e.notes))
        }
        let missing = request.items.map(\.id).filter { !seen.contains($0) }
        if !missing.isEmpty && !allowPartial { throw Failure.missingIDs(missing) }
        // Keep request order.
        let order = Dictionary(uniqueKeysWithValues: request.items.enumerated().map { ($1.id, $0) })
        return (outputs.sorted { order[$0.regionID]! < order[$1.regionID]! }, missing)
    }
}
