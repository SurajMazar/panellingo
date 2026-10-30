import CoreGraphics
import Foundation
import PanelLingoKit

/// Headless PanelLingo: the same pipeline as the app, for scripting and end-to-end verification.
@main
struct PanelLingoCLI {
    static func usage() -> Never {
        print("""
        panellingo-cli — translate comics from the command line

        USAGE
          panellingo-cli translate <file|folder|cbz|pdf> --to <lang> [--from <lang>|auto]
                        [--provider apple|ollama|lmStudio|openAI|anthropic|gemini|openRouter|customOpenAI|deepL]
                        [--model <name>] [--base-url <url>] [--direction rtl|ltr|ttb]
                        [--ocr vision|aiVision] [--cleanup fast|balanced|quality]
                        [--project <out.panellingo>] [--out <dir|file.cbz|file.pdf>] [--json <file>]
                        [--series <name>] [--chapter <number>]   (default: guessed from the file name)
          panellingo-cli detect <image> [--from <lang>] [--direction rtl|ltr|ttb]
          panellingo-cli sample <out.png> [--kind ja|en|ko|zh|none]
          panellingo-cli models --provider <kind> [--base-url <url>]
          panellingo-cli languages
          panellingo-cli library [<folder>]      list chapters and translation progress

        API keys are read from the macOS Keychain (set them in the app) or PANELLINGO_<PROVIDER>_KEY.
        """)
        exit(2)
    }

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else { usage() }
        args.removeFirst()
        var positional: [String] = []
        var flags: [String: String] = [:]
        var i = 0
        while i < args.count {
            if args[i].hasPrefix("--") {
                let k = String(args[i].dropFirst(2))
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") { flags[k] = args[i + 1]; i += 2 } else { flags[k] = "1"; i += 1 }
            } else { positional.append(args[i]); i += 1 }
        }
        do {
            switch cmd {
            case "translate": try await translate(positional, flags)
            case "detect": try await detect(positional, flags)
            case "sample": try sample(positional, flags)
            case "models": try await models(flags)
            case "languages": await languages()
            case "library": library(positional)
            default: usage()
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func direction(_ s: String?) -> ReadingDirection {
        switch s { case "ltr": .leftToRight; case "ttb": .topToBottom; default: .rightToLeft }
    }

    static func translate(_ pos: [String], _ f: [String: String]) async throws {
        guard let input = pos.first, let to = f["to"] else { usage() }
        var settings = ProjectSettings()
        settings.sourceLanguage = f["from"] ?? "auto"
        settings.targetLanguage = to
        settings.readingDirection = direction(f["direction"])
        settings.translationProvider = ProviderKind(rawValue: f["provider"] ?? "apple") ?? .apple
        settings.translationModel = f["model"] ?? ""
        settings.ocrEngine = OCREngineKind(rawValue: f["ocr"] ?? "vision") ?? .vision
        settings.cleanupMode = CleanupMode(rawValue: f["cleanup"] ?? "balanced") ?? .balanced
        let projectURL = URL(fileURLWithPath: f["project"] ?? NSTemporaryDirectory() + "panellingo-cli-\(UUID().uuidString.prefix(8)).panellingo")
        let store = try ProjectStore.create(at: projectURL, title: URL(fileURLWithPath: input).deletingPathExtension().lastPathComponent, settings: settings)
        let guess = ChapterLibrary.guess(from: URL(fileURLWithPath: input).lastPathComponent)
        try store.updateManifest { $0.series = f["series"] ?? guess.series; $0.chapter = f["chapter"] ?? guess.chapter }
        let report = await DefaultComicImportService().importItems([URL(fileURLWithPath: input)], into: store)
        print(report.summary)
        for fl in report.failures { print("  ✗ \(fl.name): \(fl.reason)") }
        var cfg = ProviderConfiguration(kind: settings.translationProvider, model: settings.translationModel)
        if let b = f["base-url"] { cfg.baseURL = b }
        let options = PipelineOptions(settings: settings, glossary: store.glossary, providers: [cfg.kind: cfg])
        let engine = PipelineEngine(store: store)
        var done: [ComicPage] = []
        for page in store.loadPages() {
            let start = Date()
            do {
                let p = try await engine.run(page, options: options)
                done.append(p)
                print("✓ \(p.name): \(p.regions.count) regions, status \(p.status.displayName) (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
                for r in p.orderedRegions {
                    let flag = r.review == .needsReview ? " ⚠︎ \(r.reviewReasons.joined(separator: "; "))" : ""
                    print("   \(r.readingIndex + 1). [\(r.kind.rawValue), \(r.orientation.rawValue), cleanup \(r.cleanup.status.rawValue)] \(r.sourceText.replacingOccurrences(of: "\n", with: " ")) → \(r.translatedText ?? "—")\(flag)")
                }
            } catch {
                print("✗ \(page.name): \(error.localizedDescription)")
                if let p = store.loadPage(page.id) { done.append(p) }
            }
        }
        let exporter = DefaultComicExportService()
        if let out = f["out"] {
            let url = URL(fileURLWithPath: out)
            let ext = url.pathExtension.lowercased()
            let format: ExportFormat = ext == "cbz" ? .cbz : ext == "pdf" ? .pdf : ext == "md" ? .markdown : ext == "jpg" ? .jpeg : .png
            var opts = ExportOptions(format: format)
            opts.fileNamePattern = "{nnn}"
            let target = (format == .png || format == .jpeg) && !ext.isEmpty ? url.deletingLastPathComponent() : url
            let files = try await exporter.export(pages: done, store: store, to: target, options: opts)
            if (format == .png || format == .jpeg), !ext.isEmpty, let first = files.first, files.count == 1, first != url {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: first, to: url)
                print("Exported \(url.path)")
            } else { print("Exported \(files.count) file(s) → \(target.path)") }
        }
        if let j = f["json"] { try FileIO.writeAtomically(try exporter.jsonExport(done, store: store), to: URL(fileURLWithPath: j)) }
        print("Project: \(projectURL.path)")
    }

    static func detect(_ pos: [String], _ f: [String: String]) async throws {
        guard let input = pos.first else { usage() }
        let image = try ImageIOHelper.cgImage(contentsOf: URL(fileURLWithPath: input))
        let from = f["from"] ?? "auto"
        let out = try await HybridTextDetector().detect(image: image, options: DetectionOptions(sourceLanguage: from, readingDirection: direction(f["direction"])))
        print("\(out.panels.count) panels, \(out.regions.count) regions (working scale \(out.workingScale))")
        for p in out.panels { print("  panel \(p.index): \(fmt(p.bbox))") }
        let ocr = VisionOCRProvider()
        for r in out.regions {
            let o = try await ocr.recognize(region: r, image: image, language: from)
            print("  \(r.readingIndex + 1). \(r.kind.rawValue) \(r.orientation.rawValue) conf \(String(format: "%.2f", r.confidence)) panel \(r.panelIndex.map(String.init) ?? "-") \(fmt(r.bbox)) → “\(o.text)” (\(String(format: "%.2f", o.confidence)), \(o.engine))")
        }
    }

    static func fmt(_ r: PixelRect) -> String { "[\(Int(r.x)),\(Int(r.y)) \(Int(r.width))×\(Int(r.height))]" }

    static func sample(_ pos: [String], _ f: [String: String]) throws {
        guard let out = pos.first else { usage() }
        let img: CGImage
        switch f["kind"] ?? "ja" {
        case "en": img = SampleComic.englishPage()
        case "ko": img = SampleComic.koreanPage()
        case "zh": img = SampleComic.chinesePage()
        case "none": img = SampleComic.noTextPage()
        default: img = SampleComic.japanesePage()
        }
        try FileIO.writeAtomically(ImageIOHelper.png(img), to: URL(fileURLWithPath: out))
        print("Wrote \(out)")
    }

    static func models(_ f: [String: String]) async throws {
        guard let kind = ProviderKind(rawValue: f["provider"] ?? "") else { usage() }
        var cfg = ProviderConfiguration(kind: kind)
        if let b = f["base-url"] { cfg.baseURL = b }
        let status = await TranslationEngine.defaultProvider(cfg).testConnection()
        print(status.message)
        for m in status.models { print("  \(m)") }
    }

    static func library(_ pos: [String]) {
        let folder = URL(fileURLWithPath: pos.first ?? (NSHomeDirectory() + "/Documents/PanelLingo"))
        let snap = SeriesLibrary(root: folder).scan()
        func row(_ c: ChapterSummary) -> String {
            "  \(c.displayTitle.padding(toLength: 22, withPad: " ", startingAt: 0)) \(c.status.displayName.padding(toLength: 15, withPad: " ", startingAt: 0)) \(c.translatedPages)/\(c.pageCount) pages"
        }
        for s in snap.series {
            let rel = s.info.related.compactMap { r in snap.series(id: r.seriesID).map { "\(r.kind.displayName.lowercased()): \($0.info.name)" } }
            print("\(s.info.name)  (\(s.translatedCount)/\(s.chapters.count) translated\(rel.isEmpty ? "" : "; " + rel.joined(separator: ", ")))")
            for c in s.chapters { print(row(c)) }
        }
        if !snap.unsorted.isEmpty { print("Unsorted"); for c in snap.unsorted { print(row(c)) } }
        print("\(snap.series.count) series, \(snap.allChapters.count) chapter(s) in \(folder.path)")
    }

    static func languages() async {
        print("Apple Vision OCR: \(VisionLanguages.supported().joined(separator: ", "))")
        print("Apple Translation: \(await AppleTranslationProvider.supportedLanguages().joined(separator: ", "))")
    }
}
