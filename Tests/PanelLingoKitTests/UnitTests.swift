import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import PanelLingoKit

@Suite("Geometry")
struct GeometryTests {
    @Test func visionNormalizedToPixels() {
        // Vision: origin bottom-left, normalised. A box at the top-left quarter of a 200×100 crop.
        let r = CoordinateConverter.pixelRect(fromVisionNormalized: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                                              in: PixelRect(x: 10, y: 20, width: 200, height: 100))
        #expect(r == PixelRect(x: 10, y: 20, width: 100, height: 50))
    }

    @Test func cgRoundTrip() {
        let r = PixelRect(x: 5, y: 10, width: 20, height: 30)
        let cg = CoordinateConverter.cgRect(r, imageHeight: 100)
        #expect(cg == CGRect(x: 5, y: 60, width: 20, height: 30))
        #expect(CoordinateConverter.cgPoint(PixelPoint(x: 1, y: 2), imageHeight: 10) == CGPoint(x: 1, y: 8))
    }

    @Test func workingScaleMapsBack() {
        let working = PixelRect(x: 50, y: 25, width: 10, height: 20)
        #expect(CoordinateConverter.toSource(working, workingScale: 0.5) == PixelRect(x: 100, y: 50, width: 20, height: 40))
        #expect(CoordinateConverter.sourcePoint(viewPoint: CGPoint(x: 300, y: 150), zoom: 1.5) == PixelPoint(x: 200, y: 100))
    }

    @Test func rectOperations() {
        let a = PixelRect(x: 0, y: 0, width: 10, height: 10), b = PixelRect(x: 5, y: 5, width: 10, height: 10)
        #expect(a.intersection(b) == PixelRect(x: 5, y: 5, width: 5, height: 5))
        #expect(a.union(b) == PixelRect(x: 0, y: 0, width: 15, height: 15))
        #expect(abs(a.iou(b) - 25.0 / 175.0) < 1e-9)
        #expect(a.coverage(by: b) == 0.25)
        #expect(PixelRect(x: 0.4, y: 0.6, width: 1.2, height: 1).integral == PixelRect(x: 0, y: 0, width: 2, height: 2))
        #expect(PixelRect(x: -5, y: -5, width: 20, height: 20).clamped(width: 10, height: 8) == PixelRect(x: 0, y: 0, width: 10, height: 8))
    }

    @Test func polygonMath() {
        let square = [PixelPoint(x: 0, y: 0), PixelPoint(x: 10, y: 0), PixelPoint(x: 10, y: 10), PixelPoint(x: 0, y: 10)]
        #expect(PolygonMath.contains(square, PixelPoint(x: 5, y: 5)))
        #expect(!PolygonMath.contains(square, PixelPoint(x: 15, y: 5)))
        #expect(PolygonMath.area(square) == 100)
        let noisy = square + [PixelPoint(x: 0, y: 5.01)]
        let line = [PixelPoint(x: 0, y: 0), PixelPoint(x: 3, y: 0.01), PixelPoint(x: 6, y: -0.01), PixelPoint(x: 10, y: 0)]
        #expect(PolygonMath.simplify(line, tolerance: 0.5).count == 2)
        #expect(PolygonMath.convexHull(noisy).count == 4)
    }

    @Test func maskMorphology() {
        var m = BitMask(width: 9, height: 9)
        m[4, 4] = true
        let d = m.dilated(2)
        #expect(d.count == 25)
        #expect(d.eroded(2).count == 1)
        var ring = BitMask(width: 7, height: 7)
        for i in 1...5 { ring[i, 1] = true; ring[i, 5] = true; ring[1, i] = true; ring[5, i] = true }
        #expect(ring.filledHoles().count == 25)
    }
}

@Suite("Utilities")
struct UtilityTests {
    @Test func naturalSort() {
        let names = ["page10.png", "page2.png", "page1.png", "Page3.png", "chapter 2/01.png", "chapter 10/01.png"]
        #expect(NaturalSort.sorted(names, by: { $0 }) == ["chapter 2/01.png", "chapter 10/01.png", "page1.png", "page2.png", "Page3.png", "page10.png"])
    }

    @Test func archivePathSanitising() {
        #expect(DefaultComicImportService.sanitizedEntryPath("../../etc/passwd") == "etc/passwd")
        #expect(DefaultComicImportService.sanitizedEntryPath("/abs/./ch1/01.png") == "abs/ch1/01.png")
        #expect(DefaultComicImportService.sanitizedEntryPath("C:\\x\\..\\y.png") == "x/y.png")
    }

    @Test func fileNameSanitising() {
        #expect(FileIO.sanitizeFileName("a/b:c?.png") == "a_b_c_.png")
        #expect(FileIO.sanitizeFileName("..hidden") == "hidden")
        #expect(FileIO.sanitizeFileName("第1話 「始まり」") == "第1話 「始まり」")
    }

    @Test func redaction() {
        let s = HTTPClient.redact("Bearer sk-abcdefghijklmnop key=AIzaSyA12345678901234567890 ok")
        #expect(!s.contains("sk-abcdef"))
        #expect(!s.contains("AIzaSy"))
    }

    @Test func textJoining() {
        #expect(TextJoiner.join(["HELLO THERE, HOW ARE", "YOU?"], language: "en") == "HELLO THERE, HOW ARE YOU?")
        #expect(TextJoiner.join(["extra-", "ordinary"], language: "en") == "extraordinary")
        #expect(TextJoiner.join(["今日は", "遠足だよ"], language: "ja") == "今日は遠足だよ")
    }

    @Test func glossaryCSVRoundTrip() {
        let entries = [GlossaryEntry(original: "ナツキ・スバル", preferred: "Natsuki Subaru", alternatives: ["Subaru", "スバル"], isCharacterName: true),
                       GlossaryEntry(original: "レム", preferred: "Rem", notes: "maid, \"blue\"")]
        let parsed = GlossaryIO.parseCSV(GlossaryIO.csv(entries))
        #expect(parsed.count == 2)
        #expect(parsed[0].alternatives == ["Subaru", "スバル"])
        #expect(parsed[0].isCharacterName)
        #expect(parsed[1].notes == "maid, \"blue\"")
    }
}

@Suite("Reading order & regions")
struct ReadingOrderTests {
    func region(_ x: Double, _ y: Double, _ w: Double = 50, _ h: Double = 50) -> TextRegion {
        TextRegion(kind: .speech, bbox: PixelRect(x: x, y: y, width: w, height: h))
    }

    @Test func mangaRightToLeftWithinPanel() {
        let panels = [ComicPanel(bbox: PixelRect(x: 0, y: 0, width: 1000, height: 1000), index: 0)]
        let left = region(100, 100), right = region(800, 120), bottom = region(500, 700)
        let ordered = ReadingOrder.order([left, bottom, right], panels: panels, direction: .rightToLeft)
        #expect(ordered.map(\.id) == [right.id, left.id, bottom.id])
        #expect(ordered.map(\.readingIndex) == [0, 1, 2])
    }

    @Test func westernLeftToRight() {
        let panels = [ComicPanel(bbox: PixelRect(x: 0, y: 0, width: 1000, height: 1000), index: 0)]
        let left = region(100, 100), right = region(800, 120)
        #expect(ReadingOrder.order([right, left], panels: panels, direction: .leftToRight).map(\.id) == [left.id, right.id])
    }

    @Test func panelOrderBeatsYCoordinate() {
        // Panel 0 is the right column (manga); a low bubble there is still read before panel 1's high bubble.
        let panels = [ComicPanel(bbox: PixelRect(x: 500, y: 0, width: 500, height: 1000), index: 0),
                      ComicPanel(bbox: PixelRect(x: 0, y: 0, width: 500, height: 1000), index: 1)]
        let lowRight = region(700, 800), highLeft = region(100, 50)
        let ordered = ReadingOrder.order([highLeft, lowRight], panels: panels, direction: .rightToLeft)
        #expect(ordered.map(\.id) == [lowRight.id, highLeft.id])
        #expect(ordered[0].panelIndex == 0 && ordered[1].panelIndex == 1)
    }

    @Test func manualOrderApplication() {
        var page = ComicPage(name: "p", originalFileName: "p.png", originalHash: "", pixelWidth: 10, pixelHeight: 10, importedFrom: nil)
        page.regions = (0..<4).map { var r = region(Double($0) * 10, 0); r.readingIndex = $0; return r }
        let ids = page.regions.map(\.id)
        ReadingOrder.apply(order: [ids[2], ids[0]], to: &page)
        #expect(page.orderedRegions.map(\.id) == [ids[2], ids[0], ids[1], ids[3]])
    }

    @Test func dedupeKeepsEnclosingBubble() {
        let bubble = TextRegion(kind: .speech, bbox: PixelRect(x: 0, y: 0, width: 100, height: 100))
        let inner = TextRegion(kind: .freeText, bbox: PixelRect(x: 20, y: 20, width: 50, height: 30))
        let other = TextRegion(kind: .freeText, bbox: PixelRect(x: 300, y: 300, width: 50, height: 30))
        let out = RegionAssembler.dedupe([inner, bubble, other])
        #expect(Set(out.map(\.id)) == [bubble.id, other.id])
    }

    @Test func lineGroupingParagraphs() {
        let lines = [
            VisionLine(rect: PixelRect(x: 100, y: 100, width: 200, height: 20), text: "HELLO", confidence: 1),
            VisionLine(rect: PixelRect(x: 110, y: 125, width: 180, height: 20), text: "THERE", confidence: 1),
            VisionLine(rect: PixelRect(x: 600, y: 600, width: 100, height: 20), text: "FAR", confidence: 1),
        ]
        let groups = RegionAssembler.groupLines(lines)
        #expect(groups.count == 2)
        #expect(groups[0].map(\.text) == ["HELLO", "THERE"])
    }

    @Test func mergeAndSplit() {
        var a = region(0, 0); a.readingIndex = 0; a.correctedText = "A"
        var b = region(0, 60); b.readingIndex = 1; b.correctedText = "B"
        let m = RegionAssembler.merge([b, a])!
        #expect(m.id == a.id)
        #expect(m.bbox == PixelRect(x: 0, y: 0, width: 50, height: 110))
        #expect(m.correctedText == "A\nB")
        let parts = RegionAssembler.split(m)
        #expect(parts.count == 2 && parts[0].bbox.maxY <= parts[1].bbox.minY)
        #expect(Set(parts.map(\.id)).count == 2)
    }
}

@Suite("Translation responses")
struct TranslationParsingTests {
    let request = TranslationRequest(sourceLanguage: "ja", targetLanguage: "en",
                                     items: [TranslationItem(id: "region-001", text: "こんにちは"), TranslationItem(id: "region-002", text: "元気？")])

    @Test func validResponse() throws {
        let json = """
        ```json
        {"translations":[{"region_id":"region-002","original_text":"元気？","translated_text":"You good?","confidence":0.8,"review_required":false,"notes":null},
        {"region_id":"region-001","original_text":"こんにちは","translated_text":"Hello!","confidence":0.96,"review_required":false,"notes":null}]}
        ```
        """
        let (out, missing) = try TranslationResponseParser.parse(json, request: request)
        #expect(missing.isEmpty)
        #expect(out.map(\.regionID) == ["region-001", "region-002"])
        #expect(out[0].translatedText == "Hello!")
        #expect(out[0].originalText == "こんにちは")
    }

    @Test func rejectsUnknownAndDuplicateIDs() {
        #expect(throws: TranslationResponseParser.Failure.unknownID("region-999")) {
            try TranslationResponseParser.parse(#"{"translations":[{"region_id":"region-999","translated_text":"x"}]}"#, request: request)
        }
        #expect(throws: TranslationResponseParser.Failure.duplicateID("region-001")) {
            try TranslationResponseParser.parse(#"{"translations":[{"region_id":"region-001","translated_text":"a"},{"region_id":"region-001","translated_text":"b"}]}"#, request: request)
        }
        #expect(throws: TranslationResponseParser.Failure.noJSON) { try TranslationResponseParser.parse("Sorry, I can't.", request: request) }
        #expect(throws: TranslationResponseParser.Failure.emptyTranslation("region-001")) {
            try TranslationResponseParser.parse(#"{"translations":[{"region_id":"region-001","translated_text":"  "}]}"#, request: request)
        }
    }

    @Test func reportsMissingIDsAndStripsThinking() throws {
        let text = "<think>hmm {not json}</think>{\"translations\":[{\"region_id\":\"region-001\",\"translated_text\":\"Hi\"}]}"
        let (out, missing) = try TranslationResponseParser.parse(text, request: request)
        #expect(out.count == 1 && missing == ["region-002"])
        #expect(throws: TranslationResponseParser.Failure.missingIDs(["region-002"])) {
            try TranslationResponseParser.parse(text, request: request, allowPartial: false)
        }
    }

    @Test func promptContainsContextGlossaryAndIDs() {
        var r = request
        r.glossary = [GlossaryEntry(original: "レム", preferred: "Rem", isCharacterName: true)]
        r.previousContext = [ContextLine(source: "前のページ", translation: "Previous page")]
        let msg = TranslationPrompt.userMessage(r)
        #expect(msg.contains("region-001") && msg.contains("レム → Rem") && msg.contains("Previous page"))
        #expect(TranslationPrompt.system.contains("Never modify, merge, or reorder IDs"))
    }
}

/// Deterministic provider for tests only (never used by the app).
struct MockTranslationProvider: TranslationProvider {
    var configuration: ProviderConfiguration
    var kind: ProviderKind { configuration.kind }
    var dropIDsOnFirstCall: Set<String> = []
    var failWith: PanelLingoError?
    let calls = Counter()

    init(kind: ProviderKind = .ollama, dropIDsOnFirstCall: Set<String> = [], failWith: PanelLingoError? = nil) {
        configuration = ProviderConfiguration(kind: kind, model: "mock")
        self.dropIDsOnFirstCall = dropIDsOnFirstCall
        self.failWith = failWith
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0; var requests: [TranslationRequest] = []
        func next(_ r: TranslationRequest) -> Int { lock.lock(); defer { lock.unlock() }; n += 1; requests.append(r); return n }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let n = calls.next(request)
        if let failWith { throw failWith }
        let items = n == 1 ? request.items.filter { !dropIDsOnFirstCall.contains($0.id) } : request.items
        return TranslationResult(outputs: items.map { TranslationOutput(regionID: $0.id, originalText: $0.text, translatedText: "EN(\($0.text))", confidence: 0.9) },
                                 provider: kind, model: "mock")
    }
    func listModels() async throws -> [String] { ["mock"] }
    func testConnection() async -> ProviderStatus { ProviderStatus(ok: true, message: "mock") }
}

@Suite("Translation engine")
struct TranslationEngineTests {
    let req = TranslationRequest(sourceLanguage: "ja", targetLanguage: "en",
                                 items: (1...5).map { TranslationItem(id: "r\($0)", text: String(repeating: "あ", count: 10)) })

    @Test func rerequestsMissingIDs() async throws {
        let mock = MockTranslationProvider(dropIDsOnFirstCall: ["r2", "r4"])
        let engine = TranslationEngine(configurations: [:], privacy: PrivacySettings()) { _ in mock }
        let res = try await engine.translate(req, provider: .ollama)
        #expect(res.outputs.map(\.regionID) == ["r1", "r2", "r3", "r4", "r5"])
        #expect(mock.calls.value == 2)
        #expect(mock.calls.requests[1].items.map(\.id) == ["r2", "r4"])
    }

    @Test func chunksLongRequests() async throws {
        let mock = MockTranslationProvider()
        var cfg = ProviderConfiguration(kind: .ollama, model: "mock"); cfg.maxCharactersPerRequest = 20
        let engine = TranslationEngine(configurations: [.ollama: cfg], privacy: PrivacySettings()) { _ in mock }
        let res = try await engine.translate(req, provider: .ollama)
        #expect(res.outputs.count == 5)
        #expect(mock.calls.value == 3)
        // Later chunks get earlier translations as context.
        #expect(mock.calls.requests[2].nearbyContext.count == 4)
    }

    @Test func localOnlyBlocksCloud() async {
        var privacy = PrivacySettings(); privacy.localOnly = true
        let engine = TranslationEngine(configurations: [:], privacy: privacy) { c in MockTranslationProvider(kind: c.kind) }
        await #expect(throws: PanelLingoError.self) { try await engine.translate(req, provider: .openAI) }
        // Local providers still work.
        let ok = try? await engine.translate(req, provider: .ollama)
        #expect(ok?.outputs.count == 5)
    }

    @Test func fallbackProviderUsedOnFailure() async throws {
        let engine = TranslationEngine(configurations: [:], privacy: PrivacySettings()) { c in
            c.kind == .lmStudio ? MockTranslationProvider(kind: .lmStudio, failWith: .provider(.lmStudio, .unauthorized)) : MockTranslationProvider(kind: c.kind)
        }
        let res = try await engine.translate(req, provider: .lmStudio, fallback: .ollama)
        #expect(res.provider == .ollama)
    }

    @Test func customEndpointLocality() {
        #expect(ProviderConfiguration(kind: .customOpenAI, baseURL: "http://localhost:8080/v1").isLocal)
        #expect(!ProviderConfiguration(kind: .customOpenAI, baseURL: "https://api.example.com/v1").isLocal)
        #expect(throws: PanelLingoError.self) { try HTTPClient.requireHTTPS("http://api.example.com", provider: .customOpenAI) }
    }
}

@Suite("Typesetting")
struct LayoutTests {
    let engine = CoreTextLayoutEngine()
    var style: TextStyle { var s = TextStylePresets.cleanSans; s.padding = 0.05; return s }

    @Test func fitsAndShrinksForLongerText() {
        let area = TextArea(rect: PixelRect(x: 0, y: 0, width: 300, height: 200), polygon: nil, inset: 10)
        let short = engine.layout(text: "Hi!", style: style, area: area, language: "en")
        let long = engine.layout(text: "This is a much longer sentence that has to wrap across several lines inside the bubble.", style: style, area: area, language: "en")
        #expect(!short.overflow && !long.overflow)
        #expect(short.fontSize > long.fontSize)
        #expect(long.lines.count > 1)
        for l in long.lines {
            #expect(l.origin.x >= 9.5 && l.origin.x + l.width <= 290.5)
        }
    }

    @Test func detectsOverflow() {
        var s = style; s.minFontSize = 30
        let area = TextArea(rect: PixelRect(x: 0, y: 0, width: 80, height: 40), polygon: nil, inset: 2)
        let r = engine.layout(text: "Supercalifragilisticexpialidocious and more words", style: s, area: area, language: "en")
        #expect(r.overflow)
    }

    @Test func neverBreaksInsideWordsWhenAvoidable() {
        let area = TextArea(rect: PixelRect(x: 0, y: 0, width: 160, height: 220), polygon: nil, inset: 4)
        let r = engine.layout(text: "Mio... I'm still sleepy.", style: style, area: area, language: "en")
        let lines = r.lines.map { line -> String in
            let range = CTLineGetStringRange(line.line)
            return String(("Mio… I'm still sleepy." as NSString).substring(with: NSRange(location: range.location, length: range.length)))
        }
        #expect(lines.first?.hasPrefix("Mio…") == true)
    }

    @Test func ellipsePolygonNarrowsTopAndBottomLines() {
        let rect = PixelRect(x: 0, y: 0, width: 300, height: 300)
        let ellipse = (0..<64).map { i -> PixelPoint in
            let a = Double(i) / 64 * 2 * .pi
            return PixelPoint(x: 150 + cos(a) * 150, y: 150 + sin(a) * 150)
        }
        let area = TextArea(rect: rect, polygon: ellipse, inset: 0)
        let top = area.span(y0: 20, y1: 40)!, mid = area.span(y0: 140, y1: 160)!
        #expect((top.1 - top.0) < (mid.1 - mid.0) * 0.7)
    }

    @Test func verticalCJKLayout() {
        var s = style; s.direction = .vertical
        let r = engine.layout(text: "こんにちは", style: s, area: TextArea(rect: PixelRect(x: 0, y: 0, width: 80, height: 300), polygon: nil, inset: 4), language: "ja")
        #expect(r.vertical && !r.overflow && r.frame != nil)
    }
}

@Suite("Undo history")
struct UndoTests {
    @Test func undoRedoRestoresPageValues() {
        let um = UndoManager()
        um.groupsByEvent = false
        var current = ComicPage(name: "p", originalFileName: "p.png", originalHash: "", pixelWidth: 10, pixelHeight: 10, importedFrom: nil)
        let history = PageHistory(undoManager: um) { current = $0 }
        let v0 = current
        var v1 = v0; v1.regions.append(TextRegion(kind: .speech, bbox: PixelRect(x: 0, y: 0, width: 5, height: 5)))
        um.beginUndoGrouping(); current = v1; history.record(previous: v0, current: v1, actionName: "Add Region"); um.endUndoGrouping()
        var v2 = v1; v2.regions[0].correctedText = "fixed"
        um.beginUndoGrouping(); current = v2; history.record(previous: v1, current: v2, actionName: "Edit"); um.endUndoGrouping()
        #expect(um.undoActionName == "Edit")
        um.undo(); #expect(current == v1)
        um.undo(); #expect(current == v0)
        um.redo(); #expect(current == v1)
        um.redo(); #expect(current == v2)
    }
}

@Suite("Mixed scripts")
struct MixedScriptTests {
    @Test func latinLinesInCJKProjectKeepSpaces() {
        #expect(TextJoiner.join(["FIVE MORE", "MINUTES..."], language: "ja") == "FIVE MORE MINUTES...")
        #expect(TextJoiner.join(["あっ、", "そうだった！"], language: "ja") == "あっ、そうだった！")
        #expect(TextJoiner.join(["안녕하세요!", "오늘 날씨가 정말 좋네요."], language: "ko") == "안녕하세요! 오늘 날씨가 정말 좋네요.")
    }
}

@Suite("Chapter library")
struct ChapterLibraryTests {
    @Test func guessesSeriesAndChapter() {
        let a = ChapterLibrary.guess(from: "regressed-warriors-female-dominance-raw-chapter-108.pdf")
        #expect(a.series == "Regressed Warriors Female Dominance" && a.chapter == "108")
        let b = ChapterLibrary.guess(from: "Solo Leveling Ch. 12.5.cbz")
        #expect(b.series == "Solo Leveling" && b.chapter == "12.5")
        let c = ChapterLibrary.guess(from: "ワンピース 第1050話")
        #expect(c.series == "ワンピース" && c.chapter == "1050")
        let d = ChapterLibrary.guess(from: "My Comic 007")
        #expect(d.series == "My Comic" && d.chapter == "7")
        #expect(ChapterLibrary.guess(from: "artbook").chapter == nil)
    }

    @Test func groupsImportsIntoChapters() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("ch-3"), withIntermediateDirectories: true)
        let urls = [dir.appendingPathComponent("b.png"), dir.appendingPathComponent("ch-2.cbz"), dir.appendingPathComponent("ch-1.pdf"),
                    dir.appendingPathComponent("ch-3"), dir.appendingPathComponent("a.png")]
        let groups = ChapterLibrary.groupIntoChapters(urls)
        #expect(groups.map(\.name) == ["ch-1", "ch-2", "ch-3", dir.lastPathComponent])
        #expect(groups.last?.items.map(\.lastPathComponent) == ["a.png", "b.png"])
    }

    @Test func scansProjectsAndReportsProgress() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = try ImageIOHelper.png(SampleComic.noTextPage())
        for (n, done) in [("10", 2), ("2", 0)] {
            let store = try ProjectStore.create(at: dir.appendingPathComponent("S ch \(n).panellingo"), title: "S ch \(n)")
            try store.updateManifest { $0.series = "S"; $0.chapter = n }
            for i in 0..<2 {
                var p = try store.addPage(imageData: png, fileExtension: "png", name: "p\(i)", importedFrom: nil)
                if i < done { p.completedStages = Set(PipelineStage.allCases); p.status = .completed; try store.savePage(p) }
            }
        }
        let chapters = ChapterLibrary.scan(folder: dir).sorted(by: ChapterLibrary.chapterOrder)
        #expect(chapters.map(\.chapter) == ["2", "10"])
        #expect(chapters[0].status == .notStarted && chapters[1].status == .translated)
        #expect(chapters[1].progress == 1 && chapters[1].pageCount == 2)
    }
}

@Suite("Series library")
struct SeriesLibraryTests {
    func tempLibrary() throws -> SeriesLibrary {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("series-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SeriesLibrary(root: dir)
    }

    func chapter(_ lib: SeriesLibrary, _ name: String, in folder: URL?) throws -> URL {
        let url = try lib.newChapterURL(name: name, in: folder)
        let s = try ProjectStore.create(at: url, title: name)
        try s.addPage(imageData: ImageIOHelper.png(SampleComic.noTextPage()), fileExtension: "png", name: "p1", importedFrom: nil)
        return url
    }

    @Test func seriesFoldersChaptersAndUnsorted() throws {
        let lib = try tempLibrary()
        var info = SeriesInfo(name: "Re:Monster"); info.alternateNames = ["リ・モンスター"]
        let folder = try lib.createSeries(info)
        #expect(folder.lastPathComponent == "Re_Monster")
        _ = try chapter(lib, "ch 10", in: folder)
        _ = try chapter(lib, "ch 2", in: folder)
        let loose = try chapter(lib, "loose", in: nil)
        var snap = lib.scan()
        #expect(snap.series.count == 1 && snap.unsorted.count == 1)
        #expect(snap.series[0].chapters.count == 2)
        #expect(snap.matchSeries(named: "re monster")?.id == info.id)
        #expect(snap.matchSeries(named: "リ・モンスター") != nil)

        // Move the loose chapter into the series.
        let moved = try lib.moveChapter(loose, toSeriesFolder: folder, seriesName: info.name)
        snap = lib.scan()
        #expect(snap.unsorted.isEmpty && snap.series[0].chapters.count == 3)
        #expect(try ProjectStore.open(moved).manifest.series == "Re:Monster")
        #expect(lib.seriesFolder(containing: moved)?.lastPathComponent == folder.lastPathComponent)
        #expect(lib.seriesFolder(containing: lib.root.appendingPathComponent("x.panellingo")) == nil)

        // Rename keeps chapters and updates their cached series name.
        info.name = "Re Monster (2024)"
        let renamed = try lib.updateSeries(info, folder: folder)
        #expect(renamed.lastPathComponent == "Re Monster _2024_" || renamed.lastPathComponent.hasPrefix("Re Monster"))
        #expect(lib.scan().series[0].chapters.count == 3)
    }

    @Test func relationsAreBidirectionalAndShareGlossary() throws {
        let lib = try tempLibrary()
        var a = SeriesInfo(name: "Main Story"); a.glossary = [GlossaryEntry(original: "ハル", preferred: "Haru")]
        var b = SeriesInfo(name: "Side Story"); b.glossary = [GlossaryEntry(original: "ミオ", preferred: "Mio"), GlossaryEntry(original: "ハル", preferred: "WRONG")]
        try lib.createSeries(a); try lib.createSeries(b)
        var snap = lib.scan()
        let main = snap.series.first { $0.info.name == "Main Story" }!, side = snap.series.first { $0.info.name == "Side Story" }!
        // "Main Story is Side Story's parent story" → Main Story gets "Side Story is my spin-off".
        try lib.link(side, main, kind: .parentStory)
        snap = lib.scan()
        let side2 = snap.series(id: side.id)!, main2 = snap.series(id: main.id)!
        #expect(side2.info.related == [SeriesRelation(seriesID: main.id, kind: .parentStory)])
        #expect(main2.info.related.first?.kind == .spinOff)
        // Side story: own glossary first, then the parent's for terms it lacks.
        let g = SeriesLibrary.effectiveGlossary(chapter: [GlossaryEntry(original: "遠足", preferred: "school trip")], series: side2, snapshot: snap)
        #expect(g.map(\.preferred) == ["school trip", "Mio", "WRONG"])
        let gm = SeriesLibrary.effectiveGlossary(chapter: [], series: main2, snapshot: snap)
        #expect(gm.map(\.preferred) == ["Haru", "Mio"])
        #expect(SeriesLibrary.effectiveStoryContext(chapter: "", series: side2, snapshot: snap).contains("Parent story: Main Story"))
        try lib.unlink(side2, main2)
        #expect(lib.scan().series.allSatisfy { $0.info.related.isEmpty })
        _ = a; _ = b
    }

    @Test func seriesDefaultsApplyToNewChapters() {
        var info = SeriesInfo(name: "K"); info.sourceLanguage = "ko"; info.readingDirection = .topToBottom
        let s = info.chapterSettings(base: ProjectSettings())
        #expect(s.sourceLanguage == "ko" && s.readingDirection == .topToBottom && s.targetLanguage == "en")
    }

    @Test func toleratesSparseSeriesJSON() throws {
        let info = try FileIO.decoder.decode(SeriesInfo.self, from: Data(#"{"name":"Old"}"#.utf8))
        #expect(info.name == "Old" && info.related.isEmpty && !info.id.isEmpty)
    }
}

@Suite("Global AI settings")
struct GlobalAISettingsTests {
    @Test func chaptersFollowGlobalUnlessCustom() {
        var global = ProjectSettings()
        global.translationProvider = .ollama; global.translationModel = "qwen3-vl:8b-instruct"
        global.ocrEngine = .aiVision; global.ocrProvider = .ollama; global.ocrModel = "qwen3-vl:4b-instruct"
        var chapter = ProjectSettings(); chapter.sourceLanguage = "ko"
        let eff = chapter.applyingGlobalAI(global)
        #expect(eff.translationProvider == .ollama && eff.translationModel == "qwen3-vl:8b-instruct")
        #expect(eff.ocrEngine == .aiVision && eff.ocrModel == "qwen3-vl:4b-instruct" && eff.sourceLanguage == "ko")
        chapter.customAI = true; chapter.translationProvider = .apple
        #expect(chapter.applyingGlobalAI(global).translationProvider == .apple)
        var noOCR = ProjectSettings(); noOCR.translationProvider = .lmStudio
        #expect(noOCR.effectiveOCRProvider == .lmStudio)
    }

    @Test func oldSettingsFilesStillDecode() throws {
        let old = #"{"sourceLanguage":"ko","targetLanguage":"en","translationProvider":"apple","ocrEngine":"vision","tone":"no-such-tone"}"#
        let s = try FileIO.decoder.decode(ProjectSettings.self, from: Data(old.utf8))
        #expect(s.sourceLanguage == "ko" && s.customAI == false && s.ocrProvider == nil && s.tone == .natural)
    }
}
