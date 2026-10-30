import Foundation

// MARK: - Enumerations

public enum RegionKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case speech, thought, caption, dialogueBox, freeText, sfx, artText
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .speech: "Speech Bubble"
        case .thought: "Thought Bubble"
        case .caption: "Narration / Caption"
        case .dialogueBox: "Dialogue Box"
        case .freeText: "Free Text"
        case .sfx: "Sound Effect"
        case .artText: "Text on Artwork"
        }
    }
    /// Regions bounded by a detected bubble/box shape.
    public var isEnclosed: Bool { self == .speech || self == .thought || self == .caption || self == .dialogueBox }
}

public enum TextOrientation: String, Codable, CaseIterable, Sendable {
    case horizontal, vertical
}

public enum ReadingDirection: String, Codable, CaseIterable, Sendable, Identifiable {
    case rightToLeft, leftToRight, topToBottom
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .rightToLeft: "Manga (Right to Left)"
        case .leftToRight: "Western (Left to Right)"
        case .topToBottom: "Webtoon (Top to Bottom)"
        }
    }
}

public enum PipelineStage: String, Codable, CaseIterable, Sendable, Comparable {
    case detect, ocr, translate, clean, typeset
    public var order: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.order < b.order }
    public var displayName: String {
        switch self {
        case .detect: "Detection"
        case .ocr: "OCR"
        case .translate: "Translation"
        case .clean: "Cleanup"
        case .typeset: "Typesetting"
        }
    }
}

public enum PageStatus: String, Codable, CaseIterable, Sendable {
    case pending, detecting, ocr, translating, cleaning, typesetting, completed, needsReview, failed
    public var displayName: String {
        switch self {
        case .pending: "Pending"
        case .detecting: "Detecting"
        case .ocr: "OCR"
        case .translating: "Translating"
        case .cleaning: "Cleaning"
        case .typesetting: "Typesetting"
        case .completed: "Completed"
        case .needsReview: "Needs Review"
        case .failed: "Failed"
        }
    }
    public var isWorking: Bool { [.detecting, .ocr, .translating, .cleaning, .typesetting].contains(self) }
    public static func working(_ stage: PipelineStage) -> PageStatus {
        switch stage {
        case .detect: .detecting
        case .ocr: .ocr
        case .translate: .translating
        case .clean: .cleaning
        case .typeset: .typesetting
        }
    }
}

public enum ReviewStatus: String, Codable, CaseIterable, Sendable {
    case unreviewed, needsReview, approved
}

public enum CleanupMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case fast, balanced, quality
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .fast: "Fast (flat fill)"
        case .balanced: "Balanced (diffusion inpaint)"
        case .quality: "Quality (neural, Core ML)"
        }
    }
}

public enum CleanupStatus: String, Codable, Sendable {
    case none, cleaned, skipped, needsReview, failed, restored
}

// MARK: - Region data

public struct RGBAColor: Codable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public static let black = RGBAColor(r: 0, g: 0, b: 0)
    public static let white = RGBAColor(r: 1, g: 1, b: 1)
    public static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)
}

public enum TextAlignmentOption: String, Codable, CaseIterable, Sendable {
    case leading, center, trailing
}

public enum TextDirectionOption: String, Codable, CaseIterable, Sendable {
    case auto, horizontal, vertical
}

public struct TextStyle: Codable, Hashable, Sendable {
    public var presetID: String
    public var fontFamily: String
    /// `nil` = auto-fit.
    public var fontSize: Double?
    public var minFontSize: Double
    public var maxFontSize: Double
    public var bold: Bool
    public var italic: Bool
    public var uppercase: Bool
    public var textColor: RGBAColor
    public var strokeColor: RGBAColor
    /// Stroke width as a fraction of the font size (0 = none).
    public var strokeWidth: Double
    public var alignment: TextAlignmentOption
    public var lineSpacing: Double
    public var direction: TextDirectionOption
    public var rotation: Double
    /// Padding inside the bubble as a fraction of the shorter side.
    public var padding: Double

    public init(presetID: String = "classic", fontFamily: String = "Comic Sans MS", fontSize: Double? = nil,
                minFontSize: Double = 8, maxFontSize: Double = 96, bold: Bool = true, italic: Bool = false,
                uppercase: Bool = false, textColor: RGBAColor = .black, strokeColor: RGBAColor = .white,
                strokeWidth: Double = 0, alignment: TextAlignmentOption = .center, lineSpacing: Double = 1.0,
                direction: TextDirectionOption = .auto, rotation: Double = 0, padding: Double = 0.1) {
        self.presetID = presetID; self.fontFamily = fontFamily; self.fontSize = fontSize
        self.minFontSize = minFontSize; self.maxFontSize = maxFontSize; self.bold = bold; self.italic = italic
        self.uppercase = uppercase; self.textColor = textColor; self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth; self.alignment = alignment; self.lineSpacing = lineSpacing
        self.direction = direction; self.rotation = rotation; self.padding = padding
    }
}

public struct TextLine: Codable, Hashable, Sendable {
    public var bbox: PixelRect
    public var text: String
    public var confidence: Double
    public init(bbox: PixelRect, text: String, confidence: Double) {
        self.bbox = bbox; self.text = text; self.confidence = confidence
    }
}

public struct OCRResult: Codable, Hashable, Sendable {
    public var text: String
    public var confidence: Double
    public var engine: String
    public var language: String?
    public var lines: [TextLine]
    /// Orientation the engine actually read the text in (may correct detection).
    public var orientation: TextOrientation?
    public var date: Date
    public init(text: String, confidence: Double, engine: String, language: String?, lines: [TextLine],
                orientation: TextOrientation? = nil, date: Date = Date()) {
        self.text = text; self.confidence = confidence; self.engine = engine; self.language = language
        self.lines = lines; self.orientation = orientation; self.date = date
    }
}

public struct TranslationRecord: Codable, Hashable, Sendable {
    public var text: String
    public var provider: String
    public var model: String?
    /// Model self-reported confidence. Not a calibrated probability.
    public var modelConfidence: Double?
    public var reviewRequired: Bool
    public var notes: String?
    /// Source text this translation was produced from (to detect staleness).
    public var sourceText: String
    public var date: Date
    public init(text: String, provider: String, model: String?, modelConfidence: Double?, reviewRequired: Bool,
                notes: String?, sourceText: String, date: Date = Date()) {
        self.text = text; self.provider = provider; self.model = model; self.modelConfidence = modelConfidence
        self.reviewRequired = reviewRequired; self.notes = notes; self.sourceText = sourceText; self.date = date
    }
}

public struct CleanupState: Codable, Hashable, Sendable {
    public var status: CleanupStatus = .none
    public var mode: CleanupMode?
    /// Mask dilation in source pixels.
    public var maskExpansion: Double = 2
    /// Edge feather radius in source pixels.
    public var feather: Double = 1
    /// Source-pixel rect covered by the stored mask / patch bitmaps.
    public var maskRect: PixelRect?
    /// Incremented every time mask bitmap changes; used for cache invalidation.
    public var maskRevision: Int = 0
    /// The user painted this mask by hand; automatic cleanup must not replace it.
    public var manualMask: Bool = false
    public var message: String?
    public init() {}
}

public struct LayoutState: Codable, Hashable, Sendable {
    public var fittedFontSize: Double?
    public var overflow: Bool = false
    public var lineCount: Int = 0
    public init() {}
}

public struct TextRegion: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: RegionKind
    public var bbox: PixelRect
    /// Outline of the bubble / box (source pixels), when known.
    public var polygon: [PixelPoint]?
    public var textLines: [TextLine]
    /// Detection confidence 0…1.
    public var confidence: Double
    public var readingIndex: Int
    public var orientation: TextOrientation
    public var panelIndex: Int?
    public var detectedLanguage: String?
    public var detector: String

    public var ocr: OCRResult?
    /// User-corrected source text. When set it always wins over OCR output.
    public var correctedText: String?
    public var translation: TranslationRecord?
    /// Translation edited or approved by a human; automatic re-translation skips it.
    public var translationLocked: Bool = false

    public var style: TextStyle
    /// Optional user-defined text area (source pixels). Defaults to the safe inner bubble area.
    public var textArea: PixelRect?
    public var cleanup: CleanupState = CleanupState()
    public var layout: LayoutState = LayoutState()

    public var locked: Bool = false
    public var doNotTranslate: Bool = false
    public var isManual: Bool = false
    public var review: ReviewStatus = .unreviewed
    public var reviewReasons: [String] = []

    public init(id: String = TextRegion.makeID(), kind: RegionKind, bbox: PixelRect, polygon: [PixelPoint]? = nil,
                textLines: [TextLine] = [], confidence: Double = 1, readingIndex: Int = 0,
                orientation: TextOrientation = .horizontal, panelIndex: Int? = nil, detector: String = "manual",
                style: TextStyle = TextStyle()) {
        self.id = id; self.kind = kind; self.bbox = bbox; self.polygon = polygon; self.textLines = textLines
        self.confidence = confidence; self.readingIndex = readingIndex; self.orientation = orientation
        self.panelIndex = panelIndex; self.detector = detector; self.style = style
    }

    public static func makeID() -> String {
        "region-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// Source text used for translation: manual correction wins over OCR.
    public var sourceText: String { correctedText ?? ocr?.text ?? "" }
    public var translatedText: String? { translation?.text }
    public var hasTranslation: Bool { !(translation?.text.isEmpty ?? true) }
    public var translationIsStale: Bool {
        guard let t = translation else { return false }
        return !translationLocked && t.sourceText != sourceText
    }

    /// Clears the review flag once no reasons remain (approved regions stay approved).
    public mutating func normalizeReview() {
        if reviewReasons.isEmpty && review == .needsReview { review = .unreviewed }
    }

    public mutating func flagReview(_ reason: String) {
        if !reviewReasons.contains(reason) { reviewReasons.append(reason) }
        if review != .approved { review = .needsReview }
    }
}

public struct ComicPanel: Codable, Hashable, Sendable {
    public var bbox: PixelRect
    public var index: Int
    public init(bbox: PixelRect, index: Int) { self.bbox = bbox; self.index = index }
}

public struct StageError: Codable, Hashable, Sendable {
    public var stage: PipelineStage
    public var message: String
    public var date: Date
    public init(stage: PipelineStage, message: String, date: Date = Date()) {
        self.stage = stage; self.message = message; self.date = date
    }
}

public struct ComicPage: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// File name inside the package `originals/` folder.
    public var originalFileName: String
    public var originalHash: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var importedFrom: String?
    public var status: PageStatus = .pending
    public var completedStages: Set<PipelineStage> = []
    public var lastError: StageError?
    public var panels: [ComicPanel] = []
    public var regions: [TextRegion] = []
    public var detectionScale: Double?

    public init(id: String = ComicPage.makeID(), name: String, originalFileName: String, originalHash: String,
                pixelWidth: Int, pixelHeight: Int, importedFrom: String?) {
        self.id = id; self.name = name; self.originalFileName = originalFileName; self.originalHash = originalHash
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.importedFrom = importedFrom
    }

    public static func makeID() -> String { "page-" + UUID().uuidString.prefix(8).lowercased() }

    public var size: (width: Double, height: Double) { (Double(pixelWidth), Double(pixelHeight)) }
    public var orderedRegions: [TextRegion] { regions.sorted { $0.readingIndex < $1.readingIndex } }

    public func regionIndex(_ id: String) -> Int? { regions.firstIndex { $0.id == id } }

    /// Removes completion of `stage` and every stage depending on it.
    public mutating func invalidate(from stage: PipelineStage) {
        completedStages = completedStages.filter { $0 < stage }
        if status == .completed || status == .needsReview { status = .pending }
    }

    public mutating func renumberReadingOrder() {
        let sorted = orderedRegions.map(\.id)
        for (i, id) in sorted.enumerated() { if let idx = regionIndex(id) { regions[idx].readingIndex = i } }
    }

    public var needsReviewCount: Int { regions.filter { $0.review == .needsReview }.count }
}

// MARK: - Project

public enum TranslationTone: String, Codable, CaseIterable, Sendable, Identifiable {
    case natural, faithful, official, casual, comedy, dramatic, custom
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .natural: "Natural / Conversational"
        case .faithful: "Faithful / Literal"
        case .official: "Official Manga Localization"
        case .casual: "Casual"
        case .comedy: "Comedy"
        case .dramatic: "Dramatic"
        case .custom: "Custom Instructions Only"
        }
    }
    public var instruction: String {
        switch self {
        case .natural: "Use natural, conversational dialogue a fluent native speaker would write."
        case .faithful: "Stay close to the literal meaning and structure while remaining grammatical."
        case .official: "Write like an official, published manga localization: polished, idiomatic, consistent."
        case .casual: "Use relaxed, casual, contemporary phrasing."
        case .comedy: "Prioritise comedic timing and punchlines; adapt jokes so they land in the target language."
        case .dramatic: "Keep dialogue intense and emotionally heightened; favour strong, dramatic word choices."
        case .custom: ""
        }
    }
}

public enum HonorificPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    case preserve, localize, drop
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .preserve: "Preserve honorifics (-san, -kun, senpai)"
        case .localize: "Localize honorifics (Mr., Ms., nicknames)"
        case .drop: "Drop honorifics"
        }
    }
}

public struct ProjectSettings: Codable, Hashable, Sendable {
    /// BCP-47 code or "auto".
    public var sourceLanguage: String = "ja"
    public var targetLanguage: String = "en"
    public var readingDirection: ReadingDirection = .rightToLeft
    public var tone: TranslationTone = .natural
    public var honorifics: HonorificPolicy = .preserve
    public var customInstructions: String = ""
    public var storyContext: String = ""
    public var translationProvider: ProviderKind = .apple
    public var translationModel: String = ""
    public var fallbackProvider: ProviderKind?
    public var ocrEngine: OCREngineKind = .vision
    /// Provider/model for AI Vision OCR (nil = same as translation).
    public var ocrProvider: ProviderKind?
    public var ocrModel: String?
    /// When false (default) the chapter follows the app-wide translation & OCR choices.
    public var customAI: Bool = false
    public var cleanupMode: CleanupMode = .balanced
    public var defaultStyle: TextStyle = TextStylePresets.classic
    public var includePreviousPageContext: Bool = true
    public init() {}

    enum CodingKeys: String, CodingKey {
        case sourceLanguage, targetLanguage, readingDirection, tone, honorifics, customInstructions, storyContext,
             translationProvider, translationModel, fallbackProvider, ocrEngine, ocrProvider, ocrModel, customAI,
             cleanupMode, defaultStyle, includePreviousPageContext
    }

    /// Tolerant decoding: missing or unknown values fall back to defaults instead of failing the whole file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProjectSettings()
        func get<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        sourceLanguage = get(.sourceLanguage, d.sourceLanguage)
        targetLanguage = get(.targetLanguage, d.targetLanguage)
        readingDirection = get(.readingDirection, d.readingDirection)
        tone = get(.tone, d.tone)
        honorifics = get(.honorifics, d.honorifics)
        customInstructions = get(.customInstructions, d.customInstructions)
        storyContext = get(.storyContext, d.storyContext)
        translationProvider = get(.translationProvider, d.translationProvider)
        translationModel = get(.translationModel, d.translationModel)
        fallbackProvider = (try? c.decodeIfPresent(ProviderKind.self, forKey: .fallbackProvider)) ?? nil
        ocrEngine = get(.ocrEngine, d.ocrEngine)
        ocrProvider = (try? c.decodeIfPresent(ProviderKind.self, forKey: .ocrProvider)) ?? nil
        ocrModel = (try? c.decodeIfPresent(String.self, forKey: .ocrModel)) ?? nil
        customAI = get(.customAI, d.customAI)
        cleanupMode = get(.cleanupMode, d.cleanupMode)
        defaultStyle = get(.defaultStyle, d.defaultStyle)
        includePreviousPageContext = get(.includePreviousPageContext, d.includePreviousPageContext)
    }

    /// The provider/model AI Vision OCR uses.
    public var effectiveOCRProvider: ProviderKind { ocrProvider ?? translationProvider }

    /// Settings with the app-wide translation & OCR choices applied, unless this chapter overrides them.
    public func applyingGlobalAI(_ global: ProjectSettings) -> ProjectSettings {
        guard !customAI else { return self }
        var s = self
        s.translationProvider = global.translationProvider
        s.translationModel = global.translationModel
        s.fallbackProvider = global.fallbackProvider
        s.ocrEngine = global.ocrEngine
        s.ocrProvider = global.ocrProvider
        s.ocrModel = global.ocrModel
        return s
    }
}

public struct GlossaryEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var original: String
    public var preferred: String
    public var alternatives: [String] = []
    public var isCharacterName: Bool = false
    public var honorificRule: String = ""
    public var notes: String = ""
    public var caseSensitive: Bool = false
    public init(original: String, preferred: String, alternatives: [String] = [], isCharacterName: Bool = false,
                honorificRule: String = "", notes: String = "", caseSensitive: Bool = false) {
        self.original = original; self.preferred = preferred; self.alternatives = alternatives
        self.isCharacterName = isCharacterName; self.honorificRule = honorificRule; self.notes = notes
        self.caseSensitive = caseSensitive
    }

    /// True when the entry's original term (or an alternative) occurs in `text`.
    public func matches(_ text: String) -> Bool {
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        return ([original] + alternatives).contains { !$0.isEmpty && text.range(of: $0, options: opts) != nil }
    }
}

public struct ProjectManifest: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1
    public var formatVersion: Int = ProjectManifest.currentFormatVersion
    public var id: String = UUID().uuidString
    public var title: String
    /// Series this chapter belongs to (optional; used to group the library).
    public var series: String?
    /// Chapter label, e.g. "108" or "12.5".
    public var chapter: String?
    public var created: Date = Date()
    public var modified: Date = Date()
    public var pageIDs: [String] = []
    public var appVersion: String = PanelLingoVersion.string
    public init(title: String) { self.title = title }
}

public enum PanelLingoVersion {
    public static let string = "1.2.0"
}
