import Foundation

/// One chat-completion call, independent of provider wire format.
public struct ChatCall: Sendable {
    public var system: String
    public var user: String
    public var imageJPEG: Data?
    public var jsonSchema: Bool
    public init(system: String, user: String, imageJPEG: Data? = nil, jsonSchema: Bool = true) {
        self.system = system; self.user = user; self.imageJPEG = imageJPEG; self.jsonSchema = jsonSchema
    }
}

/// LLM-backed translation for Ollama, LM Studio, OpenAI, Anthropic, Gemini, OpenRouter and
/// custom OpenAI-compatible endpoints. Each wire format is implemented natively.
public struct LLMTranslationProvider: TranslationProvider {
    public let configuration: ProviderConfiguration
    public var kind: ProviderKind { configuration.kind }
    let apiKey: String?
    let http: HTTPClient

    public init(configuration: ProviderConfiguration, apiKey: String? = nil) {
        self.configuration = configuration
        self.apiKey = apiKey ?? KeychainStore.get(configuration.kind)
        self.http = HTTPClient(timeout: configuration.timeoutSeconds)
    }

    var base: String { configuration.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }

    func url(_ path: String) throws -> URL {
        _ = try HTTPClient.requireHTTPS(base, provider: kind)
        guard let u = URL(string: base + path) else { throw PanelLingoError.provider(kind, .notConfigured("invalid endpoint URL")) }
        return u
    }

    func requireKey() throws -> String {
        guard let k = apiKey, !k.isEmpty else {
            throw PanelLingoError.provider(kind, .notConfigured("add an API key in Settings › AI Providers"))
        }
        return k
    }

    func requireModel() throws -> String {
        let m = configuration.model.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { throw PanelLingoError.provider(kind, .notConfigured("choose a model")) }
        return m
    }

    // MARK: TranslationProvider

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let call = ChatCall(system: TranslationPrompt.system, user: TranslationPrompt.userMessage(request),
                            imageJPEG: request.pageImageJPEG, jsonSchema: true)
        let text = try await complete(call)
        do {
            // Partial results are returned; the engine re-requests any missing IDs.
            let (outputs, missing) = try TranslationResponseParser.parse(text, request: request)
            if outputs.isEmpty { throw TranslationResponseParser.Failure.missingIDs(missing) }
            return TranslationResult(outputs: outputs, provider: kind, model: configuration.model)
        } catch let f as TranslationResponseParser.Failure {
            throw PanelLingoError.provider(kind, .malformedResponse(f.description))
        }
    }

    public func listModels() async throws -> [String] {
        switch kind {
        case .ollama:
            let o = try await http.json("GET", url: url("/api/tags"), provider: kind)
            return ((o["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.sorted()
        case .anthropic:
            let o = try await http.json("GET", url: url("/v1/models?limit=100"), headers: anthropicHeaders(), provider: kind)
            return ((o["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        case .gemini:
            let o = try await http.json("GET", url: url("/models?pageSize=200"), headers: ["x-goog-api-key": try requireKey()], provider: kind)
            return ((o["models"] as? [[String: Any]]) ?? []).filter {
                (($0["supportedGenerationMethods"] as? [String]) ?? []).contains("generateContent")
            }.compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
        default:
            var headers: [String: String] = [:]
            if let k = apiKey, !k.isEmpty { headers["Authorization"] = "Bearer \(k)" } else if kind.requiresAPIKey { _ = try requireKey() }
            let o = try await http.json("GET", url: url("/models"), headers: headers, provider: kind)
            return ((o["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
        }
    }

    public func testConnection() async -> ProviderStatus {
        do {
            let models = try await listModels()
            let m = configuration.model
            if !m.isEmpty, !models.isEmpty, !models.contains(m), kind != .openRouter {
                return ProviderStatus(ok: false, message: "Connected, but model “\(m)” was not found. \(models.count) models available.", models: models)
            }
            return ProviderStatus(ok: true, message: "Connected — \(models.count) model\(models.count == 1 ? "" : "s") available.", models: models)
        } catch {
            return ProviderStatus(ok: false, message: error.localizedDescription)
        }
    }

    // MARK: Chat completion

    /// Sends one chat call and returns the assistant's text.
    public func complete(_ call: ChatCall) async throws -> String {
        let model = try requireModel()
        switch kind {
        case .ollama: return try await ollama(call, model: model)
        case .anthropic: return try await anthropic(call, model: model)
        case .gemini: return try await gemini(call, model: model)
        case .apple, .deepL: throw PanelLingoError.provider(kind, .notConfigured("not a chat model provider"))
        default: return try await openAICompatible(call, model: model)
        }
    }

    func openAICompatible(_ call: ChatCall, model: String) async throws -> String {
        var headers: [String: String] = [:]
        if let k = apiKey, !k.isEmpty { headers["Authorization"] = "Bearer \(k)" } else if kind.requiresAPIKey { _ = try requireKey() }
        if kind == .openRouter { headers["HTTP-Referer"] = "https://github.com/SurajMazar/panellingo"; headers["X-Title"] = "PanelLingo" }
        var userContent: Any = call.user
        if let img = call.imageJPEG {
            userContent = [["type": "text", "text": call.user],
                           ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(img.base64EncodedString())"]]]
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": call.system], ["role": "user", "content": userContent]],
        ]
        // Reasoning models only accept the default temperature.
        let reasoning = kind == .openAI && (model.hasPrefix("gpt-5") || model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4"))
        if !reasoning { body["temperature"] = configuration.temperature }
        if call.jsonSchema && (kind == .openAI || kind == .lmStudio) {
            body["response_format"] = ["type": "json_schema",
                                       "json_schema": ["name": "comic_translations", "strict": true, "schema": TranslationPrompt.jsonSchema]]
        }
        let o = try await http.json(url: url("/chat/completions"), headers: headers, body: body, provider: kind)
        guard let choices = o["choices"] as? [[String: Any]], let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw PanelLingoError.provider(kind, .malformedResponse("no message content"))
        }
        return content
    }

    func ollama(_ call: ChatCall, model: String) async throws -> String {
        var user: [String: Any] = ["role": "user", "content": call.user]
        if let img = call.imageJPEG { user["images"] = [img.base64EncodedString()] }
        var body: [String: Any] = [
            "model": model, "stream": false,
            "messages": [["role": "system", "content": call.system], user],
            "options": ["temperature": configuration.temperature],
        ]
        if call.jsonSchema { body["format"] = TranslationPrompt.jsonSchema }
        let o = try await http.json(url: url("/api/chat"), body: body, provider: kind)
        if let err = o["error"] as? String {
            if err.contains("not found") { throw PanelLingoError.provider(kind, .modelNotFound(model)) }
            throw PanelLingoError.provider(kind, .server(500, err))
        }
        guard let msg = o["message"] as? [String: Any], let content = msg["content"] as? String else {
            throw PanelLingoError.provider(kind, .malformedResponse("no message content"))
        }
        return content
    }

    func anthropicHeaders() throws -> [String: String] {
        ["x-api-key": try requireKey(), "anthropic-version": "2023-06-01"]
    }

    func anthropic(_ call: ChatCall, model: String) async throws -> String {
        var content: [[String: Any]] = []
        if let img = call.imageJPEG {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": img.base64EncodedString()]])
        }
        content.append(["type": "text", "text": call.user])
        let body: [String: Any] = [
            "model": model, "max_tokens": 8192, "system": call.system,
            "temperature": configuration.temperature,
            "messages": [["role": "user", "content": content]],
        ]
        let o = try await http.json(url: url("/v1/messages"), headers: try anthropicHeaders(), body: body, provider: kind)
        guard let blocks = o["content"] as? [[String: Any]] else {
            throw PanelLingoError.provider(kind, .malformedResponse("no content blocks"))
        }
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        if text.isEmpty { throw PanelLingoError.provider(kind, .malformedResponse("empty response")) }
        return text
    }

    func gemini(_ call: ChatCall, model: String) async throws -> String {
        var parts: [[String: Any]] = [["text": call.user]]
        if let img = call.imageJPEG { parts.append(["inline_data": ["mime_type": "image/jpeg", "data": img.base64EncodedString()]]) }
        var gen: [String: Any] = ["temperature": configuration.temperature]
        if call.jsonSchema { gen["responseMimeType"] = "application/json" }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": call.system]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": gen,
        ]
        let path = "/models/\(model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model):generateContent"
        let o = try await http.json(url: url(path), headers: ["x-goog-api-key": try requireKey()], body: body, provider: kind)
        guard let cands = o["candidates"] as? [[String: Any]], let c = cands.first?["content"] as? [String: Any],
              let ps = c["parts"] as? [[String: Any]] else {
            let reason = ((o["promptFeedback"] as? [String: Any])?["blockReason"] as? String) ?? "no candidates"
            throw PanelLingoError.provider(kind, .malformedResponse(reason))
        }
        return ps.compactMap { $0["text"] as? String }.joined()
    }
}

/// DeepL REST API adapter (Free and Pro keys).
public struct DeepLTranslationProvider: TranslationProvider {
    public let configuration: ProviderConfiguration
    public var kind: ProviderKind { .deepL }
    let apiKey: String?
    let http: HTTPClient

    public init(configuration: ProviderConfiguration, apiKey: String? = nil) {
        self.configuration = configuration
        self.apiKey = apiKey ?? KeychainStore.get(.deepL)
        self.http = HTTPClient(timeout: configuration.timeoutSeconds)
    }

    var baseURL: String {
        // Free keys end in ":fx" and must use the free endpoint.
        if let k = apiKey, configuration.baseURL == ProviderKind.deepL.defaultBaseURL || configuration.baseURL.contains("deepl.com") {
            return k.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com"
        }
        return configuration.baseURL
    }

    func headers() throws -> [String: String] {
        guard let k = apiKey, !k.isEmpty else { throw PanelLingoError.provider(.deepL, .notConfigured("add a DeepL API key")) }
        return ["Authorization": "DeepL-Auth-Key \(k)"]
    }

    static func sourceCode(_ c: String) -> String? {
        if c == "auto" { return nil }
        if c.hasPrefix("zh") { return "ZH" }
        return c.split(separator: "-").first.map { $0.uppercased() }
    }

    static func targetCode(_ c: String) -> String {
        switch c {
        case "en": return "EN-US"
        case "pt": return "PT-BR"
        case "zh-Hans": return "ZH-HANS"
        case "zh-Hant": return "ZH-HANT"
        default: return c.uppercased()
        }
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let url = try HTTPClient.requireHTTPS(baseURL + "/v2/translate", provider: .deepL)
        var body: [String: Any] = ["text": request.items.map(\.text), "target_lang": Self.targetCode(request.targetLanguage)]
        if let s = Self.sourceCode(request.sourceLanguage) { body["source_lang"] = s }
        let ctx = (request.previousContext + request.nearbyContext).map(\.source) + [request.storyContext]
        let joined = ctx.filter { !$0.isEmpty }.joined(separator: "\n")
        if !joined.isEmpty { body["context"] = String(joined.prefix(4000)) }
        let o = try await http.json(url: url, headers: try headers(), body: body, provider: .deepL)
        guard let arr = o["translations"] as? [[String: Any]], arr.count == request.items.count else {
            throw PanelLingoError.provider(.deepL, .malformedResponse("translation count mismatch"))
        }
        let outputs = zip(request.items, arr).map { item, t in
            TranslationOutput(regionID: item.id, originalText: item.text,
                              translatedText: GlossaryApplier.apply(request.glossary, to: (t["text"] as? String) ?? "", source: item.text))
        }
        return TranslationResult(outputs: outputs, provider: .deepL, model: nil)
    }

    public func listModels() async throws -> [String] { [] }

    public func testConnection() async -> ProviderStatus {
        do {
            let url = try HTTPClient.requireHTTPS(baseURL + "/v2/usage", provider: .deepL)
            let o = try await http.json("GET", url: url, headers: try headers(), provider: .deepL)
            let used = o["character_count"] as? Int ?? 0, limit = o["character_limit"] as? Int ?? 0
            return ProviderStatus(ok: true, message: "Connected — \(used) / \(limit) characters used this period.")
        } catch { return ProviderStatus(ok: false, message: error.localizedDescription) }
    }
}

/// Applies glossary preferred spellings to machine translation output (non-LLM providers).
public enum GlossaryApplier {
    public static func apply(_ glossary: [GlossaryEntry], to text: String, source: String) -> String {
        var out = text
        for g in glossary where g.matches(source) {
            for alt in g.alternatives where !alt.isEmpty {
                out = out.replacingOccurrences(of: alt, with: g.preferred, options: g.caseSensitive ? [] : [.caseInsensitive])
            }
        }
        return out
    }
}
