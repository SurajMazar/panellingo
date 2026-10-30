import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZIPFoundation
@testable import PanelLingoKit

/// End-to-end pipeline tests on the procedurally drawn fixtures (real Vision OCR, real cleanup and
/// typesetting; only the translator is mocked).
@Suite("Pipeline integration", .serialized)
struct PipelineIntegrationTests {
    static func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("panellingo-tests-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func makeStore(_ image: CGImage, source: String, direction: ReadingDirection = .rightToLeft) throws -> (ProjectStore, ComicPage) {
        var s = ProjectSettings()
        s.sourceLanguage = source; s.targetLanguage = "en"; s.readingDirection = direction
        s.translationProvider = .ollama; s.translationModel = "mock"
        let store = try ProjectStore.create(at: tempDir().appendingPathComponent("t.panellingo"), title: "Test", settings: s)
        let page = try store.addPage(imageData: ImageIOHelper.png(image), fileExtension: "png", name: "p1", importedFrom: nil)
        return (store, page)
    }

    static func engine(_ store: ProjectStore, provider: MockTranslationProvider = MockTranslationProvider()) -> PipelineEngine {
        let e = PipelineEngine(store: store)
        e.translationProviderFactory = { _ in provider }
        return e
    }

    @Test func japaneseVerticalSliceEndToEnd() async throws {
        let (store, page) = try Self.makeStore(SampleComic.japanesePage(), source: "ja")
        let mock = MockTranslationProvider()
        let options = PipelineOptions(settings: store.settings, glossary: [GlossaryEntry(original: "ハル", preferred: "Haru", isCharacterName: true)])
        let done = try await Self.engine(store, provider: mock).run(page, options: options)

        // Detection + OCR: the five real bubbles, not the faces.
        #expect(done.regions.count == 5)
        let texts = done.orderedRegions.map(\.sourceText)
        #expect(texts.contains { $0.contains("おはよう") })
        #expect(texts.contains { $0.contains("遠足") })
        #expect(done.regions.filter { $0.orientation == .vertical }.count >= 3)
        // Reading order: right-to-left in the top panel → caption/“ハル” bubble before “ミオ”.
        let haru = done.orderedRegions.firstIndex { $0.sourceText.contains("ハル") }!
        let mio = done.orderedRegions.firstIndex { $0.sourceText.contains("まだ") }!
        #expect(haru < mio)
        // Translation via (mock) provider with context + glossary in the request.
        #expect(done.regions.allSatisfy { $0.translatedText?.hasPrefix("EN(") == true })
        #expect(mock.calls.requests.first?.glossary.count == 1)
        // Cleanup + typesetting.
        #expect(done.regions.allSatisfy { $0.cleanup.status == .cleaned })
        #expect(PipelineStage.allCases.allSatisfy { done.completedStages.contains($0) })

        // Preservation: pixels outside every cleanup mask are bit-identical to the original.
        let original = try store.originalImage(done)
        let cleaned = try PageRenderer().render(page: done, original: original, layers: store, mode: .cleaned, targetLanguage: "en")
        let a = RGBAImage(original), b = RGBAImage(cleaned)
        #expect(a.width == b.width && a.height == b.height)
        var masked = BitMask(width: a.width, height: a.height)
        for r in done.regions {
            guard let rect = r.cleanup.maskRect, let m = store.loadMask(pageID: done.id, regionID: r.id) else { continue }
            for y in 0..<m.height { for x in 0..<m.width where m[x, y] { masked[Int(rect.x) + x, Int(rect.y) + y] = true } }
        }
        var changedOutside = 0, changedInside = 0
        for i in 0..<(a.width * a.height) {
            let differs = a.pixels[i * 4] != b.pixels[i * 4] || a.pixels[i * 4 + 1] != b.pixels[i * 4 + 1] || a.pixels[i * 4 + 2] != b.pixels[i * 4 + 2]
            if differs { if masked.bits[i] != 0 { changedInside += 1 } else { changedOutside += 1 } }
        }
        #expect(changedOutside == 0)
        #expect(changedInside > 1000)

        // Lettering is clipped to the regions: translated vs cleaned only differ inside region areas.
        let translated = try PageRenderer().render(page: done, original: original, layers: store, mode: .translated, targetLanguage: "en")
        let t = RGBAImage(translated)
        let areas = done.regions.map { TextArea.forRegion($0).rect.insetBy(dx: -3, dy: -3) }
        var strayText = 0
        for y in 0..<t.height { for x in 0..<t.width {
            let i = (y * t.width + x) * 4
            if t.pixels[i] != b.pixels[i] || t.pixels[i + 1] != b.pixels[i + 1] {
                if !areas.contains(where: { $0.contains(PixelPoint(x: Double(x), y: Double(y))) }) { strayText += 1 }
            }
        } }
        #expect(strayText == 0)

        // Export keeps original resolution.
        let out = Self.tempDir()
        let files = try await DefaultComicExportService().export(pages: [done], store: store, to: out, options: ExportOptions(format: .png))
        let exported = try ImageIOHelper.cgImage(contentsOf: files[0])
        #expect(exported.width == done.pixelWidth && exported.height == done.pixelHeight)
    }

    @Test func manualEditsSurviveSaveReopenAndReprocessing() async throws {
        let (store, page) = try Self.makeStore(SampleComic.englishPage(), source: "en", direction: .leftToRight)
        var s = store.settings; s.targetLanguage = "fr"; try store.saveSettings(s)
        let engine = Self.engine(store)
        var done = try await engine.run(page, options: PipelineOptions(settings: store.settings))
        #expect(done.regions.count >= 3)
        #expect(done.regions.contains { $0.sourceText.uppercased().contains("AWAKE") })
        let ids = done.regions.map(\.id)

        // User corrects OCR, edits a translation and changes styling.
        let target = done.orderedRegions[0].id
        let i = done.regionIndex(target)!
        done.regions[i].correctedText = "HEY! ARE YOU AWAKE YET?"
        done.regions[i].translation?.text = "Hé ! Tu es réveillé ?"
        done.regions[i].translationLocked = true
        done.regions[i].style.fontSize = 33
        try store.savePage(done)

        // Reopen from disk.
        let reopened = try ProjectStore.open(store.url)
        var p = try #require(reopened.loadPage(page.id))
        #expect(p.regions.map(\.id) == ids)
        #expect(p.regions[i].translatedText == "Hé ! Tu es réveillé ?")
        #expect(p.regions[i].style.fontSize == 33)

        // Re-running OCR + translation must not overwrite the confirmed correction or approved translation.
        p = try await Self.engine(reopened).run(p, request: PipelineRequest(stages: [.ocr, .translate, .typeset], force: true),
                                                options: PipelineOptions(settings: reopened.settings))
        #expect(p.regions[i].correctedText == "HEY! ARE YOU AWAKE YET?")
        #expect(p.regions[i].translatedText == "Hé ! Tu es réveillé ?")
        #expect(p.regions.map(\.id) == ids)
    }

    @Test func failureKeepsEarlierStagesAndRetryResumes() async throws {
        let (store, page) = try Self.makeStore(SampleComic.koreanPage(), source: "ko", direction: .leftToRight)
        let failing = MockTranslationProvider(failWith: .provider(.ollama, .unreachable("offline")))
        await #expect(throws: PanelLingoError.self) {
            _ = try await Self.engine(store, provider: failing).run(page, options: PipelineOptions(settings: store.settings))
        }
        let failed = try #require(store.loadPage(page.id))
        #expect(failed.status == .failed)
        #expect(failed.lastError?.stage == .translate)
        #expect(failed.completedStages == [.detect, .ocr])
        #expect(failed.regions.first?.sourceText.contains("안녕하세요") == true)
        let regionIDs = failed.regions.map(\.id)

        // Retry with a working provider: detection/OCR are not repeated (IDs unchanged).
        let ok = MockTranslationProvider()
        let done = try await Self.engine(store, provider: ok).run(failed, options: PipelineOptions(settings: store.settings))
        #expect(done.regions.map(\.id) == regionIDs)
        #expect(done.status == .completed || done.status == .needsReview)
        #expect(ok.calls.value == 1)
    }

    @Test func chineseAndNoTextFixtures() async throws {
        let (store, page) = try Self.makeStore(SampleComic.chinesePage(), source: "zh-Hans", direction: .leftToRight)
        let done = try await Self.engine(store).run(page, request: PipelineRequest(stages: [.detect, .ocr]), options: PipelineOptions(settings: store.settings))
        #expect(done.regions.contains { $0.sourceText.contains("你好") })

        let (store2, blank) = try Self.makeStore(SampleComic.noTextPage(), source: "ja")
        let none = try await Self.engine(store2).run(blank, options: PipelineOptions(settings: store2.settings))
        #expect(none.regions.isEmpty)
        #expect(none.status == .completed)
    }

    @Test func batchContinuesPastFailuresAndPersists() async throws {
        let (store, _) = try Self.makeStore(SampleComic.englishPage(), source: "en", direction: .leftToRight)
        try store.addPage(imageData: ImageIOHelper.png(SampleComic.noTextPage()), fileExtension: "png", name: "p2", importedFrom: nil)
        // Corrupt original for page 3: processing must fail but not stop the batch.
        let bad = try store.addPage(imageData: ImageIOHelper.png(SampleComic.noTextPage()), fileExtension: "png", name: "p3", importedFrom: nil)
        try Data("not an image".utf8).write(to: store.originalURL(bad))
        let engine = Self.engine(store)
        final class Box: @unchecked Sendable { var snap: BatchQueue.Snapshot? }
        let box = Box()
        let queue = BatchQueue(engine: engine, options: PipelineOptions(settings: store.settings), concurrency: 2,
                               onPage: { _ in }, onSnapshot: { box.snap = $0 })
        await queue.start(pageIDs: store.manifest.pageIDs)
        for _ in 0..<600 {
            let s = await queue.snapshot
            if s.order.allSatisfy({ s.states[$0]?.isFinished == true }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let s = await queue.snapshot
        #expect(s.failed == 1)
        #expect(s.finished == 3)
        let reloaded = store.loadPages()
        #expect(reloaded.filter { $0.completedStages.count == 5 }.count == 2)
    }
}

@Suite("Import & export")
struct ImportExportTests {
    @Test func cbzImportNaturalOrderAndTraversalSafety() async throws {
        let dir = PipelineIntegrationTests.tempDir()
        let cbz = dir.appendingPathComponent("chapter.cbz")
        let archive = try Archive(url: cbz, accessMode: .create)
        let png = try ImageIOHelper.png(SampleComic.noTextPage())
        for name in ["10.png", "2.png", "1.png", "../evil.png", "__MACOSX/._1.png"] {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(png.count), compressionMethod: .deflate) { pos, size in
                png.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
        let store = try ProjectStore.create(at: dir.appendingPathComponent("p.panellingo"), title: "C")
        var svc = DefaultComicImportService(); svc.allowDuplicates = true
        let report = await svc.importItems([cbz], into: store)
        #expect(report.added.map(\.name) == ["1", "2", "10", "evil"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("evil.png").path))
        // Duplicate detection.
        let again = await DefaultComicImportService().importItems([cbz], into: store)
        #expect(again.added.isEmpty && again.duplicates.count == 4)
    }

    @Test func pdfImportAndExports() async throws {
        let dir = PipelineIntegrationTests.tempDir()
        let pdfURL = dir.appendingPathComponent("in.pdf")
        let doc = PDFDocument()
        doc.insert(PDFPage(image: NSImage(cgImage: SampleComic.englishPage(), size: NSSize(width: 550, height: 750)))!, at: 0)
        doc.write(to: pdfURL)
        let store = try ProjectStore.create(at: dir.appendingPathComponent("p.panellingo"), title: "PDF")
        // Image-only PDF: imported at the embedded image's native size, not re-rendered at the default DPI.
        let report = await DefaultComicImportService().importItems([pdfURL], into: store)
        let page = try #require(report.added.first)
        #expect(page.pixelWidth == 1100 && page.pixelHeight == 1500)

        let exporter = DefaultComicExportService()
        let cbz = dir.appendingPathComponent("out.cbz")
        _ = try await exporter.export(pages: store.loadPages(), store: store, to: cbz, options: ExportOptions(format: .cbz))
        let names = try Archive(url: cbz, accessMode: .read).map(\.path)
        #expect(names == ["001.png"])
        let pdf = dir.appendingPathComponent("out.pdf")
        _ = try await exporter.export(pages: store.loadPages(), store: store, to: pdf, options: ExportOptions(format: .pdf))
        #expect(PDFDocument(url: pdf)?.pageCount == 1)
        let md = exporter.transcript(store.loadPages(), store: store)
        #expect(md.contains("# PDF"))
        let json = try exporter.jsonExport(store.loadPages(), store: store)
        #expect(String(decoding: json, as: UTF8.self).contains("\"pages\""))
        #expect(!String(decoding: json, as: UTF8.self).lowercased().contains("api_key"))
    }

    @Test func projectFormatVersioning() throws {
        let dir = PipelineIntegrationTests.tempDir()
        let store = try ProjectStore.create(at: dir.appendingPathComponent("v.panellingo"), title: "V")
        var m = store.manifest; m.formatVersion = 99
        try FileIO.writeAtomically(FileIO.encoder.encode(m), to: store.url.appendingPathComponent("manifest.json"))
        #expect(throws: PanelLingoError.self) { try ProjectStore.open(store.url) }
    }
}

/// Real Apple Translation check (needs the ko→en pack): `PANELLINGO_E2E_APPLE=1 swift test`.
@Suite("Apple Translation E2E", .enabled(if: ProcessInfo.processInfo.environment["PANELLINGO_E2E_APPLE"] != nil))
struct AppleTranslationE2ETests {
    @Test func koreanToEnglish() async throws {
        let (store, page) = try PipelineIntegrationTests.makeStore(SampleComic.koreanPage(), source: "ko", direction: .leftToRight)
        var s = store.settings; s.translationProvider = .apple; s.translationModel = ""
        let done = try await PipelineEngine(store: store).run(page, options: PipelineOptions(settings: s))
        #expect(done.regions.first?.sourceText == "안녕하세요! 오늘 날씨가 정말 좋네요.")
        #expect(done.regions.first?.translatedText?.lowercased().contains("weather") == true)
    }
}

/// Optional real local-model check: `PANELLINGO_E2E_OLLAMA_MODEL=qwen3-vl:8b-instruct swift test`.
@Suite("Local provider E2E", .enabled(if: ProcessInfo.processInfo.environment["PANELLINGO_E2E_OLLAMA_MODEL"] != nil))
struct LocalProviderE2ETests {
    @Test func ollamaTranslatesSample() async throws {
        let model = ProcessInfo.processInfo.environment["PANELLINGO_E2E_OLLAMA_MODEL"]!
        let (store, page) = try PipelineIntegrationTests.makeStore(SampleComic.japanesePage(), source: "ja")
        var s = store.settings; s.translationProvider = .ollama; s.translationModel = model
        let done = try await PipelineEngine(store: store).run(page, options: PipelineOptions(settings: s,
            providers: [.ollama: ProviderConfiguration(kind: .ollama, model: model)]))
        #expect(done.regions.count == 5)
        #expect(done.regions.allSatisfy { ($0.translatedText ?? "").range(of: "[A-Za-z]", options: .regularExpression) != nil })
    }
}
