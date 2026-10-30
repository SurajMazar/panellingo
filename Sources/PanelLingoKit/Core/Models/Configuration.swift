import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case apple, ollama, lmStudio, openAI, anthropic, gemini, openRouter, customOpenAI, deepL

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apple: "Apple Translation (on-device)"
        case .ollama: "Ollama (local)"
        case .lmStudio: "LM Studio (local)"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .openRouter: "OpenRouter"
        case .customOpenAI: "Custom OpenAI-compatible"
        case .deepL: "DeepL"
        }
    }

    public var shortName: String {
        switch self {
        case .apple: "Apple"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        case .openRouter: "OpenRouter"
        case .customOpenAI: "Custom"
        case .deepL: "DeepL"
        }
    }

    /// Whether data leaves the machine. Custom endpoints are treated as remote unless they point at localhost.
    public func isLocal(baseURL: String) -> Bool {
        switch self {
        case .apple, .ollama, .lmStudio: return true
        case .customOpenAI:
            guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
            return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
        default: return false
        }
    }

    public var isLLM: Bool { self != .apple && self != .deepL }
    public var requiresAPIKey: Bool { [.openAI, .anthropic, .gemini, .openRouter, .deepL].contains(self) }
    public var supportsVision: Bool { [.ollama, .lmStudio, .openAI, .anthropic, .gemini, .openRouter, .customOpenAI].contains(self) }

    public var defaultBaseURL: String {
        switch self {
        case .apple: ""
        case .ollama: "http://localhost:11434"
        case .lmStudio: "http://localhost:1234/v1"
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .customOpenAI: "http://localhost:8080/v1"
        case .deepL: "https://api-free.deepl.com"
        }
    }

    public var suggestedModels: [String] {
        switch self {
        case .openAI: ["gpt-5-mini", "gpt-5", "gpt-4.1-mini", "gpt-4.1"]
        case .anthropic: ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]
        case .gemini: ["gemini-2.5-flash", "gemini-2.5-pro"]
        case .openRouter: ["anthropic/claude-sonnet-5-5", "openai/gpt-5-mini", "google/gemini-2.5-flash"]
        default: []
        }
    }
}

public struct ProviderConfiguration: Codable, Hashable, Sendable, Identifiable {
    public var kind: ProviderKind
    public var baseURL: String
    public var model: String
    public var temperature: Double = 0.3
    public var timeoutSeconds: Double = 120
    public var retryCount: Int = 2
    /// Maximum requests per minute (0 = unlimited).
    public var requestsPerMinute: Int = 0
    /// Maximum characters of source text per request (larger pages are split).
    public var maxCharactersPerRequest: Int = 6000
    public var id: String { kind.rawValue }

    public init(kind: ProviderKind, baseURL: String? = nil, model: String = "") {
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.model = model.isEmpty ? (kind.suggestedModels.first ?? "") : model
    }

    public var isLocal: Bool { kind.isLocal(baseURL: baseURL) }
}

public enum OCREngineKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case vision, aiVision
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .vision: "Apple Vision (on-device)"
        case .aiVision: "AI Vision model"
        }
    }
}

/// Privacy controls enforced by the pipeline before any network request.
public struct PrivacySettings: Codable, Hashable, Sendable {
    public var localOnly: Bool = false
    public var allowSendingText: Bool = true
    public var allowSendingImages: Bool = false
    public var verboseLogging: Bool = false
    public init() {}
}

public struct ProcessingSettings: Codable, Hashable, Sendable {
    public var concurrentPages: Int = 2
    public var concurrentLocalInference: Int = 1
    public var reviewOCRConfidenceThreshold: Double = 0.45
    public var reviewTranslationConfidenceThreshold: Double = 0.5
    public var detectionSensitivity: Double = 0.5
    public var maxWorkingPixels: Int = 40_000_000
    public init() {}
}

/// Language metadata. Engine capability is always checked at runtime; this list is just the catalog.
public struct LanguageInfo: Hashable, Sendable, Identifiable {
    public var code: String
    public var name: String
    public var visionCode: String?
    public var usesSpaces: Bool
    public var isRTL: Bool
    public var supportsVertical: Bool
    public var id: String { code }

    public static let all: [LanguageInfo] = [
        .init(code: "en", name: "English", visionCode: "en-US", usesSpaces: true, isRTL: false, supportsVertical: false),
        .init(code: "ja", name: "Japanese", visionCode: "ja-JP", usesSpaces: false, isRTL: false, supportsVertical: true),
        .init(code: "ko", name: "Korean", visionCode: "ko-KR", usesSpaces: true, isRTL: false, supportsVertical: true),
        .init(code: "zh-Hans", name: "Chinese (Simplified)", visionCode: "zh-Hans", usesSpaces: false, isRTL: false, supportsVertical: true),
        .init(code: "zh-Hant", name: "Chinese (Traditional)", visionCode: "zh-Hant", usesSpaces: false, isRTL: false, supportsVertical: true),
        .init(code: "fr", name: "French", visionCode: "fr-FR", usesSpaces: true, isRTL: false, supportsVertical: false),
        .init(code: "es", name: "Spanish", visionCode: "es-ES", usesSpaces: true, isRTL: false, supportsVertical: false),
        .init(code: "de", name: "German", visionCode: "de-DE", usesSpaces: true, isRTL: false, supportsVertical: false),
        .init(code: "pt", name: "Portuguese", visionCode: "pt-BR", usesSpaces: true, isRTL: false, supportsVertical: false),
        .init(code: "it", name: "Italian", visionCode: "it-IT", usesSpaces: true, isRTL: false, supportsVertical: false),
        .init(code: "ru", name: "Russian", visionCode: "ru-RU", usesSpaces: true, isRTL: false, supportsVertical: false),
        .init(code: "uk", name: "Ukrainian", visionCode: "uk-UA", usesSpaces: true, isRTL: false, supportsVertical: false),
        .init(code: "ar", name: "Arabic", visionCode: "ar-SA", usesSpaces: true, isRTL: true, supportsVertical: false),
        .init(code: "hi", name: "Hindi", visionCode: nil, usesSpaces: true, isRTL: false, supportsVertical: false),
        .init(code: "ne", name: "Nepali", visionCode: nil, usesSpaces: true, isRTL: false, supportsVertical: false),
        .init(code: "th", name: "Thai", visionCode: "th-TH", usesSpaces: false, isRTL: false, supportsVertical: false),
        .init(code: "vi", name: "Vietnamese", visionCode: "vi-VT", usesSpaces: true, isRTL: false, supportsVertical: false),
        .init(code: "id", name: "Indonesian", visionCode: nil, usesSpaces: true, isRTL: false, supportsVertical: false),
        .init(code: "tr", name: "Turkish", visionCode: "tr-TR", usesSpaces: true, isRTL: false, supportsVertical: false),
        .init(code: "pl", name: "Polish", visionCode: "pl-PL", usesSpaces: true, isRTL: false, supportsVertical: false),
        .init(code: "nl", name: "Dutch", visionCode: "nl-NL", usesSpaces: true, isRTL: false, supportsVertical: false),
    ]

    public static func info(_ code: String) -> LanguageInfo? {
        all.first { $0.code == code } ?? all.first { code.hasPrefix($0.code) }
    }

    public static func name(_ code: String) -> String {
        if code == "auto" { return "Auto-detect" }
        return info(code)?.name ?? Locale.current.localizedString(forIdentifier: code) ?? code
    }
}
