import Foundation

/// Provider-independent translation orchestration: privacy enforcement, request chunking,
/// retries with backoff, re-requesting missing IDs, rate limiting and fallback providers.
public struct TranslationEngine: Sendable {
    public var configurations: [ProviderKind: ProviderConfiguration]
    public var privacy: PrivacySettings
    public var makeProvider: @Sendable (ProviderConfiguration) -> TranslationProvider
    public var maxItemsPerRequest = 40

    static let limiters = RateLimiterRegistry()

    public init(configurations: [ProviderKind: ProviderConfiguration], privacy: PrivacySettings,
                makeProvider: (@Sendable (ProviderConfiguration) -> TranslationProvider)? = nil) {
        self.configurations = configurations
        self.privacy = privacy
        self.makeProvider = makeProvider ?? TranslationEngine.defaultProvider
    }

    public static func defaultProvider(_ c: ProviderConfiguration) -> TranslationProvider {
        switch c.kind {
        case .apple: AppleTranslationProvider(configuration: c)
        case .deepL: DeepLTranslationProvider(configuration: c)
        default: LLMTranslationProvider(configuration: c)
        }
    }

    public func configuration(_ kind: ProviderKind, model: String? = nil) -> ProviderConfiguration {
        var c = configurations[kind] ?? ProviderConfiguration(kind: kind)
        if let model, !model.isEmpty { c.model = model }
        return c
    }

    /// Throws when privacy settings forbid sending this request to `config`.
    public func checkPrivacy(_ config: ProviderConfiguration, sendsImage: Bool) throws {
        guard !config.isLocal else { return }
        if privacy.localOnly {
            throw PanelLingoError.privacy("Local-only mode is on: \(config.kind.shortName) would send text off this Mac. Choose Apple, Ollama or LM Studio, or turn off Local-only mode in Settings › Privacy.")
        }
        if !privacy.allowSendingText {
            throw PanelLingoError.privacy("Sending text to cloud providers is disabled in Settings › Privacy.")
        }
        if sendsImage && !privacy.allowSendingImages {
            throw PanelLingoError.privacy("Sending images to cloud providers is disabled in Settings › Privacy.")
        }
    }

    public func translate(_ request: TranslationRequest, provider kind: ProviderKind, model: String? = nil,
                          fallback: ProviderKind? = nil, fallbackModel: String? = nil) async throws -> TranslationResult {
        do {
            return try await translate(request, config: configuration(kind, model: model))
        } catch let e as PanelLingoError {
            guard let fb = fallback, fb != kind, !isUserFixable(e) else { throw e }
            Log.pipeline.notice("primary provider failed, using fallback \(fb.rawValue, privacy: .public)")
            return try await translate(request, config: configuration(fb, model: fallbackModel))
        }
    }

    func isUserFixable(_ e: PanelLingoError) -> Bool {
        if case .privacy = e { return true }
        if case .cancelled = e { return true }
        return false
    }

    public func translate(_ request: TranslationRequest, config: ProviderConfiguration) async throws -> TranslationResult {
        var request = request
        if !privacy.allowSendingImages || !config.kind.supportsVision { request.pageImageJPEG = nil }
        try checkPrivacy(config, sendsImage: request.pageImageJPEG != nil)
        let provider = makeProvider(config)
        var outputs: [TranslationOutput] = []
        var done: [ContextLine] = []
        for chunk in chunks(request.items, maxChars: config.maxCharactersPerRequest) {
            try Task.checkCancellation()
            var sub = request
            sub.items = chunk
            sub.nearbyContext = request.nearbyContext + done
            let result = try await translateChunk(sub, provider: provider, config: config)
            outputs += result
            done += result.map { ContextLine(source: $0.originalText, translation: $0.translatedText) }
        }
        return TranslationResult(outputs: outputs, provider: config.kind, model: config.model.isEmpty ? nil : config.model)
    }

    func chunks(_ items: [TranslationItem], maxChars: Int) -> [[TranslationItem]] {
        var out: [[TranslationItem]] = [], cur: [TranslationItem] = [], size = 0
        for i in items {
            if !cur.isEmpty && (size + i.text.count > maxChars || cur.count >= maxItemsPerRequest) {
                out.append(cur); cur = []; size = 0
            }
            cur.append(i); size += i.text.count
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Translates one chunk, retrying transient failures and re-requesting missing IDs.
    func translateChunk(_ request: TranslationRequest, provider: TranslationProvider, config: ProviderConfiguration) async throws -> [TranslationOutput] {
        var collected: [String: TranslationOutput] = [:]
        var pending = request
        var attempt = 0
        while true {
            try Task.checkCancellation()
            await Self.limiters.wait(config.kind, perMinute: config.requestsPerMinute)
            do {
                let r = try await provider.translate(pending)
                let wanted = Set(pending.items.map(\.id))
                for o in r.outputs where wanted.contains(o.regionID) { collected[o.regionID] = o }
                let missing = pending.items.filter { collected[$0.id] == nil }
                if missing.isEmpty { break }
                attempt += 1
                if attempt > config.retryCount {
                    throw PanelLingoError.provider(config.kind, .malformedResponse("no translation returned for \(missing.count) region(s)"))
                }
                pending.items = missing
                pending.nearbyContext = request.nearbyContext + collected.values.map { ContextLine(source: $0.originalText, translation: $0.translatedText) }
            } catch let e as PanelLingoError {
                guard case .provider(_, let f) = e, f.isRetryable, attempt < config.retryCount else { throw e }
                attempt += 1
                var delay = pow(2.0, Double(attempt))
                if case .rateLimited(let ra) = f, let ra { delay = max(delay, ra) }
                try await Task.sleep(nanoseconds: UInt64(min(delay, 60) * 1_000_000_000))
            } catch is CancellationError {
                throw PanelLingoError.cancelled
            }
        }
        return request.items.compactMap { collected[$0.id] }
    }
}

actor RateLimiterRegistry {
    private var limiters: [ProviderKind: RateLimiter] = [:]
    func wait(_ kind: ProviderKind, perMinute: Int) async {
        guard perMinute > 0 else { return }
        let l = limiters[kind] ?? RateLimiter()
        limiters[kind] = l
        try? await l.wait(perMinute: perMinute)
    }
}
