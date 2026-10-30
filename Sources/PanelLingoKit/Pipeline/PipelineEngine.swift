import CoreGraphics
import Foundation

public struct PipelineOptions: Sendable {
    public var settings: ProjectSettings
    public var glossary: [GlossaryEntry]
    public var providers: [ProviderKind: ProviderConfiguration]
    public var privacy: PrivacySettings
    public var processing: ProcessingSettings
    /// Send a downscaled page image along with the dialogue (vision-capable providers, if privacy allows).
    public var includePageImage: Bool

    public init(settings: ProjectSettings, glossary: [GlossaryEntry] = [], providers: [ProviderKind: ProviderConfiguration] = [:],
                privacy: PrivacySettings = PrivacySettings(), processing: ProcessingSettings = ProcessingSettings(),
                includePageImage: Bool = false) {
        self.settings = settings; self.glossary = glossary; self.providers = providers; self.privacy = privacy
        self.processing = processing; self.includePageImage = includePageImage
    }
}

/// What to (re)run for a page.
public struct PipelineRequest: Sendable {
    public var stages: [PipelineStage]
    /// Restrict OCR / translation / cleanup / typesetting to these regions (nil = all).
    public var regionIDs: Set<String>?
    /// Re-run stages even when already complete (still never overwrites locked/manual work).
    public var force: Bool

    public init(stages: [PipelineStage] = PipelineStage.allCases, regionIDs: Set<String>? = nil, force: Bool = false) {
        self.stages = stages.sorted(); self.regionIDs = regionIDs; self.force = force
    }

    public static let full = PipelineRequest()
    public static func only(_ s: PipelineStage, regions: Set<String>? = nil) -> PipelineRequest {
        PipelineRequest(stages: [s], regionIDs: regions, force: true)
    }
}

/// Runs Detect → OCR → Translate → Clean → Typeset for one page, persisting after every stage.
///
/// Each stage only replaces its own outputs, never user-confirmed data (corrected source text,
/// locked translations, manual masks, locked regions). A failure keeps all earlier results.
public final class PipelineEngine: @unchecked Sendable {
    public let store: ProjectStore
    public var detector: TextDetectionProvider = HybridTextDetector()
    public var cleanup = CleanupService()
    public var renderer = PageRenderer()
    public var translationProviderFactory: (@Sendable (ProviderConfiguration) -> TranslationProvider)?
    public var ocrOverride: OCRProvider?

    public init(store: ProjectStore) { self.store = store }

    public typealias Update = @Sendable (ComicPage) -> Void

    public func run(_ input: ComicPage, request: PipelineRequest = .full, options: PipelineOptions,
                    onUpdate: Update? = nil) async throws -> ComicPage {
        var page = input
        let image = try store.originalImage(page)
        for stage in request.stages {
            try Task.checkCancellation()
            if !request.force && page.completedStages.contains(stage) && request.regionIDs == nil { continue }
            page.status = .working(stage)
            page.lastError = nil
            onUpdate?(page)
            do {
                switch stage {
                case .detect: try await detect(&page, image: image, options: options)
                case .ocr: try await ocr(&page, image: image, request: request, options: options)
                case .translate: try await translate(&page, image: image, request: request, options: options)
                case .clean: try clean(&page, image: image, request: request, options: options)
                case .typeset: try typeset(&page, image: image, request: request, options: options)
                }
                page.completedStages.insert(stage)
                try store.savePage(page)
            } catch {
                let cancelled = error is CancellationError || (error as? PanelLingoError).map { if case .cancelled = $0 { return true }; return false } ?? false
                page.status = cancelled ? .pending : .failed
                page.lastError = cancelled ? nil : StageError(stage: stage, message: error.localizedDescription)
                try? store.savePage(page)
                onUpdate?(page)
                if cancelled { throw PanelLingoError.cancelled }
                throw PanelLingoError.stage(stage, error.localizedDescription)
            }
            onUpdate?(page)
        }
        for i in page.regions.indices { page.regions[i].normalizeReview() }
        let allDone = PipelineStage.allCases.allSatisfy { page.completedStages.contains($0) }
        page.status = page.needsReviewCount > 0 ? .needsReview : (allDone ? .completed : .pending)
        try store.savePage(page)
        onUpdate?(page)
        return page
    }

    // MARK: Detect

    func detect(_ page: inout ComicPage, image: CGImage, options: PipelineOptions) async throws {
        let opts = DetectionOptions(sourceLanguage: options.settings.sourceLanguage, readingDirection: options.settings.readingDirection,
                                    sensitivity: options.processing.detectionSensitivity, maxWorkingPixels: options.processing.maxWorkingPixels,
                                    defaultStyle: options.settings.defaultStyle)
        let out = try await detector.detect(image: image, options: opts)
        // Keep user-owned regions; replace automatic ones.
        let kept = page.regions.filter { $0.locked || $0.isManual }
        for r in page.regions where !(r.locked || r.isManual) { store.removeRegionLayers(pageID: page.id, regionID: r.id) }
        let fresh = out.regions.filter { n in !kept.contains { $0.bbox.iou(n.bbox) > 0.5 } }
        page.panels = out.panels
        page.detectionScale = out.workingScale
        page.regions = ReadingOrder.order(kept + fresh, panels: out.panels, direction: options.settings.readingDirection)
        page.invalidate(from: .ocr)
    }

    // MARK: OCR

    func ocrProvider(_ options: PipelineOptions) -> OCRProvider {
        if let o = ocrOverride { return o }
        switch options.settings.ocrEngine {
        case .vision: return VisionOCRProvider()
        case .aiVision:
            var cfg = options.providers[options.settings.translationProvider] ?? ProviderConfiguration(kind: options.settings.translationProvider)
            if !options.settings.translationModel.isEmpty { cfg.model = options.settings.translationModel }
            return AIVisionOCRProvider(configuration: cfg, privacy: options.privacy)
        }
    }

    func ocr(_ page: inout ComicPage, image: CGImage, request: PipelineRequest, options: PipelineOptions) async throws {
        let provider = ocrProvider(options)
        let threshold = options.processing.reviewOCRConfidenceThreshold
        var spurious: Set<String> = []
        for i in page.regions.indices {
            try Task.checkCancellation()
            let r = page.regions[i]
            if let ids = request.regionIDs, !ids.contains(r.id) { continue }
            if r.locked { continue }
            if !request.force && r.ocr != nil { continue }
            let result = try await provider.recognize(region: r, image: image, language: options.settings.sourceLanguage)
            page.regions[i].ocr = result
            page.regions[i].detectedLanguage = result.language ?? r.detectedLanguage
            if let o = result.orientation, !r.isManual { page.regions[i].orientation = o }
            page.regions[i].reviewReasons.removeAll { $0.hasPrefix("OCR") }
            // Automatic detections with no readable text (faces, buttons, art) are dropped so cleanup
            // can never touch them. User-drawn regions are always kept.
            let stripped = result.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
            if Self.isSpurious(r, ocrText: stripped, confidence: result.confidence) { spurious.insert(r.id); continue }
            if result.text.isEmpty { page.regions[i].flagReview("OCR found no text") }
            else if result.confidence < threshold && r.correctedText == nil { page.regions[i].flagReview("OCR confidence low") }
        }
        if !spurious.isEmpty {
            for id in spurious { store.removeRegionLayers(pageID: page.id, regionID: id) }
            page.regions.removeAll { spurious.contains($0.id) }
            page.renumberReadingOrder()
        }
        page.invalidate(from: .translate)
    }

    static func isSpurious(_ r: TextRegion, ocrText stripped: String, confidence: Double) -> Bool {
        guard !r.isManual, !r.locked, r.correctedText == nil, r.detector != "manual" else { return false }
        let visionSupport = r.textLines.contains { $0.confidence >= 0.5 && $0.text.count >= 2 }
        if stripped.isEmpty { return !visionSupport || r.textLines.isEmpty }
        return stripped.count <= 1 && confidence < 0.6 && !visionSupport
    }

    // MARK: Translate

    public func previousPageContext(of page: ComicPage) -> [ContextLine] {
        let ids = store.manifest.pageIDs
        guard let i = ids.firstIndex(of: page.id), i > 0, let prev = store.loadPage(ids[i - 1]) else { return [] }
        return prev.orderedRegions.filter { !$0.sourceText.isEmpty }.map { ContextLine(source: $0.sourceText, translation: $0.translatedText) }
    }

    func translate(_ page: inout ComicPage, image: CGImage, request: PipelineRequest, options: PipelineOptions) async throws {
        let s = options.settings
        let targets = page.orderedRegions.filter { r in
            if let ids = request.regionIDs, !ids.contains(r.id) { return false }
            guard !r.doNotTranslate, !r.locked, !r.translationLocked, !r.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return request.force || r.translation == nil || r.translationIsStale
        }
        if targets.isEmpty { return }
        var req = TranslationRequest(sourceLanguage: s.sourceLanguage, targetLanguage: s.targetLanguage,
                                     items: targets.map { TranslationItem(id: $0.id, text: $0.sourceText, kind: $0.kind.rawValue) })
        let targetIDs = Set(targets.map(\.id))
        req.nearbyContext = page.orderedRegions.filter { !targetIDs.contains($0.id) && !$0.sourceText.isEmpty }
            .map { ContextLine(source: $0.sourceText, translation: $0.translatedText) }
        if s.includePreviousPageContext { req.previousContext = previousPageContext(of: page) }
        req.glossary = options.glossary
        req.tone = s.tone
        req.honorifics = s.honorifics
        req.customInstructions = s.customInstructions
        req.storyContext = s.storyContext
        if options.includePageImage && options.privacy.allowSendingImages {
            req.pageImageJPEG = AIVisionOCRProvider.jpeg(image, scale: min(1, 1536 / Double(max(image.width, image.height))))
        }
        var engine = TranslationEngine(configurations: options.providers, privacy: options.privacy, makeProvider: translationProviderFactory)
        engine.maxItemsPerRequest = 40
        let result = try await engine.translate(req, provider: s.translationProvider, model: s.translationModel,
                                                fallback: s.fallbackProvider)
        let threshold = options.processing.reviewTranslationConfidenceThreshold
        for o in result.outputs {
            guard let i = page.regionIndex(o.regionID) else { continue }
            let src = page.regions[i].sourceText
            page.regions[i].translation = TranslationRecord(text: o.translatedText, provider: result.provider.rawValue, model: result.model,
                                                            modelConfidence: o.confidence, reviewRequired: o.reviewRequired,
                                                            notes: o.notes, sourceText: src)
            page.regions[i].reviewReasons.removeAll { $0.hasPrefix("Translation") }
            if o.reviewRequired { page.regions[i].flagReview("Translation flagged by model" + (o.notes.map { ": \($0)" } ?? "")) }
            else if let c = o.confidence, c < threshold { page.regions[i].flagReview("Translation confidence low") }
        }
        page.invalidate(from: .typeset)
    }

    // MARK: Clean

    func clean(_ page: inout ComicPage, image: CGImage, request: PipelineRequest, options: PipelineOptions) throws {
        for i in page.regions.indices {
            let r = page.regions[i]
            if let ids = request.regionIDs, !ids.contains(r.id) { continue }
            if r.locked || r.doNotTranslate { continue }
            if !request.force && r.cleanup.status != .none { continue }
            try cleanRegion(&page, index: i, image: image, mode: options.settings.cleanupMode)
        }
    }

    /// Cleans one region, honouring a manually painted mask when present.
    public func cleanRegion(_ page: inout ComicPage, index i: Int, image: CGImage, mode: CleanupMode) throws {
        let r = page.regions[i]
        var manual: (PixelRect, BitMask)?
        if r.cleanup.manualMask, let rect = r.cleanup.maskRect, let m = store.loadMask(pageID: page.id, regionID: r.id) {
            manual = (rect, m)
        }
        let out = try cleanup.clean(image: image, region: r, mode: mode, manualMask: manual)
        var state = r.cleanup
        state.status = out.status
        state.mode = out.mode
        state.maskRect = out.rect
        state.maskRevision += 1
        state.message = out.message
        try store.saveMask(out.mask, pageID: page.id, regionID: r.id)
        if let p = out.patch?.cgImage() { try store.savePatch(p, pageID: page.id, regionID: r.id) } else { store.removePatch(pageID: page.id, regionID: r.id) }
        page.regions[i].cleanup = state
        page.regions[i].reviewReasons.removeAll { $0.hasPrefix("Cleanup") }
        if out.status == .needsReview { page.regions[i].flagReview("Cleanup: \(out.message ?? "check result")") }
    }

    // MARK: Typeset

    func typeset(_ page: inout ComicPage, image: CGImage, request: PipelineRequest, options: PipelineOptions) throws {
        let engine = CoreTextLayoutEngine()
        for i in page.regions.indices {
            let r = page.regions[i]
            if let ids = request.regionIDs, !ids.contains(r.id) { continue }
            page.regions[i].reviewReasons.removeAll { $0.hasPrefix("Text overflow") }
            guard let t = r.translatedText, !t.isEmpty, !r.doNotTranslate else { page.regions[i].layout = LayoutState(); continue }
            let res = engine.layout(text: t, style: r.style, area: TextArea.forRegion(r), language: options.settings.targetLanguage)
            page.regions[i].layout.fittedFontSize = res.fontSize
            page.regions[i].layout.overflow = res.overflow
            page.regions[i].layout.lineCount = res.lines.count
            if res.overflow { page.regions[i].flagReview("Text overflow: shorten the translation or enlarge the text area") }
        }
        if let rendered = try? renderer.render(page: page, original: image, layers: store, mode: .translated,
                                                targetLanguage: options.settings.targetLanguage) {
            store.writePreview(for: page, image: rendered)
        }
    }
}
