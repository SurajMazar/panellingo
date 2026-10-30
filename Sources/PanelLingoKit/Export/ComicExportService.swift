import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import ZIPFoundation

public enum ExportFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case png, jpeg, pdf, cbz, json, markdown, project
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .png: "PNG images"
        case .jpeg: "JPEG images"
        case .pdf: "PDF document"
        case .cbz: "CBZ comic archive"
        case .json: "JSON (regions, OCR, translations, styling)"
        case .markdown: "Markdown transcript"
        case .project: "PanelLingo project package"
        }
    }
    public var producesFolder: Bool { self == .png || self == .jpeg }
    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .pdf: "pdf"
        case .cbz: "cbz"
        case .json: "json"
        case .markdown: "md"
        case .project: ProjectStore.fileExtension
        }
    }
}

public struct ExportOptions: Sendable {
    public var format: ExportFormat
    public var jpegQuality: Double = 0.92
    /// Tokens: {project} {page} {n} {nn} {nnn}
    public var fileNamePattern: String = "{project} - {nnn}"
    public var mode: RenderMode = .translated
    public var pdfDPI: Double = 150
    public init(format: ExportFormat) { self.format = format }
}

public protocol ComicExportService: Sendable {
    func export(pages: [ComicPage], store: ProjectStore, to url: URL, options: ExportOptions,
                progress: (@Sendable (Double) -> Void)?) async throws -> [URL]
}

/// Exports flattened translated pages (no editor overlays) at original resolution, plus data formats.
public struct DefaultComicExportService: ComicExportService {
    public var renderer = PageRenderer()
    public init() {}

    public static func unresolvedIssues(_ pages: [ComicPage]) -> [String] {
        var out: [String] = []
        for p in pages {
            let review = p.regions.filter { $0.review == .needsReview }.count
            let untranslated = p.regions.filter { !$0.doNotTranslate && !$0.sourceText.isEmpty && !$0.hasTranslation }.count
            let overflow = p.regions.filter { $0.layout.overflow }.count
            if p.status == .failed { out.append("\(p.name): processing failed (\(p.lastError?.message ?? "unknown"))") }
            if review > 0 { out.append("\(p.name): \(review) region(s) need review") }
            if untranslated > 0 { out.append("\(p.name): \(untranslated) region(s) untranslated") }
            if overflow > 0 { out.append("\(p.name): \(overflow) region(s) overflow") }
        }
        return out
    }

    public func fileName(pattern: String, project: String, page: ComicPage, index: Int, ext: String) -> String {
        var s = pattern
        s = s.replacingOccurrences(of: "{project}", with: project)
        s = s.replacingOccurrences(of: "{page}", with: page.name)
        s = s.replacingOccurrences(of: "{nnn}", with: String(format: "%03d", index + 1))
        s = s.replacingOccurrences(of: "{nn}", with: String(format: "%02d", index + 1))
        s = s.replacingOccurrences(of: "{n}", with: String(index + 1))
        return FileIO.sanitizeFileName(s, fallback: String(format: "%03d", index + 1)) + "." + ext
    }

    public func renderPage(_ page: ComicPage, store: ProjectStore, mode: RenderMode) throws -> CGImage {
        let original = try store.originalImage(page)
        return try renderer.render(page: page, original: original, layers: store, mode: mode, targetLanguage: store.settings.targetLanguage)
    }

    public func export(pages: [ComicPage], store: ProjectStore, to url: URL, options: ExportOptions,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> [URL] {
        let title = store.manifest.title
        switch options.format {
        case .png, .jpeg:
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var out: [URL] = []
            for (i, p) in pages.enumerated() {
                try Task.checkCancellation()
                let img = try renderPage(p, store: store, mode: options.mode)
                let type: UTType = options.format == .png ? .png : .jpeg
                let data = try ImageIOHelper.encode(img, type: type, quality: options.jpegQuality)
                let dest = url.appendingPathComponent(fileName(pattern: options.fileNamePattern, project: title, page: p, index: i, ext: options.format.fileExtension))
                try FileIO.writeAtomically(data, to: dest)
                out.append(dest)
                progress?(Double(i + 1) / Double(pages.count))
            }
            return out
        case .pdf:
            try exportPDF(pages, store: store, to: url, options: options, progress: progress)
            return [url]
        case .cbz:
            try exportCBZ(pages, store: store, to: url, options: options, progress: progress)
            return [url]
        case .json:
            try FileIO.writeAtomically(jsonExport(pages, store: store), to: url)
            return [url]
        case .markdown:
            try FileIO.writeAtomically(Data(transcript(pages, store: store).utf8), to: url)
            return [url]
        case .project:
            _ = try store.duplicate(to: url)
            return [url]
        }
    }

    func exportPDF(_ pages: [ComicPage], store: ProjectStore, to url: URL, options: ExportOptions, progress: (@Sendable (Double) -> Void)?) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw PanelLingoError.stage(.typeset, "PDF writer") }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info = [kCGPDFContextTitle: store.manifest.title, kCGPDFContextCreator: "PanelLingo"] as CFDictionary
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, info) else { throw PanelLingoError.stage(.typeset, "PDF context") }
        for (i, p) in pages.enumerated() {
            try Task.checkCancellation()
            let img = try renderPage(p, store: store, mode: options.mode)
            // Page size from pixels at the chosen DPI; the image is embedded at full resolution.
            var media = CGRect(x: 0, y: 0, width: Double(img.width) * 72 / options.pdfDPI, height: Double(img.height) * 72 / options.pdfDPI)
            let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(pageInfo)
            ctx.interpolationQuality = .high
            ctx.draw(img, in: media)
            ctx.endPDFPage()
            progress?(Double(i + 1) / Double(pages.count))
        }
        ctx.closePDF()
        try FileIO.writeAtomically(data as Data, to: url)
    }

    func exportCBZ(_ pages: [ComicPage], store: ProjectStore, to url: URL, options: ExportOptions, progress: (@Sendable (Double) -> Void)?) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(6)).tmp")
        try? FileManager.default.removeItem(at: tmp)
        let archive: Archive
        do { archive = try Archive(url: tmp, accessMode: .create) } catch { throw PanelLingoError.stage(.typeset, "cannot create archive: \(error.localizedDescription)") }
        let digits = max(3, String(pages.count).count)
        for (i, p) in pages.enumerated() {
            try Task.checkCancellation()
            let img = try renderPage(p, store: store, mode: options.mode)
            let data = try ImageIOHelper.png(img)
            // Zero-padded names keep page order in every comic reader.
            let name = String(format: "%0\(digits)d.png", i + 1)
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
            progress?(Double(i + 1) / Double(pages.count))
        }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    struct JSONExport: Encodable {
        var title: String
        var exported: Date
        var appVersion: String
        var settings: ProjectSettings
        var glossary: [GlossaryEntry]
        var pages: [ComicPage]
    }

    public func jsonExport(_ pages: [ComicPage], store: ProjectStore) throws -> Data {
        try FileIO.encoder.encode(JSONExport(title: store.manifest.title, exported: Date(), appVersion: PanelLingoVersion.string,
                                             settings: store.settings, glossary: store.glossary, pages: pages))
    }

    public func transcript(_ pages: [ComicPage], store: ProjectStore) -> String {
        let s = store.settings
        var md = "# \(store.manifest.title)\n\n"
        md += "_\(LanguageInfo.name(s.sourceLanguage)) → \(LanguageInfo.name(s.targetLanguage)) · exported by PanelLingo \(PanelLingoVersion.string)_\n\n"
        for p in pages {
            md += "## \(p.name)\n\n"
            let regions = p.orderedRegions.filter { !$0.sourceText.isEmpty || $0.hasTranslation }
            if regions.isEmpty { md += "_No text._\n\n"; continue }
            for r in regions {
                md += "\(r.readingIndex + 1). **\(r.kind.displayName)**"
                if r.review == .needsReview { md += " ⚠︎" }
                md += "\n   - \(s.sourceLanguage): \(r.sourceText.replacingOccurrences(of: "\n", with: " "))\n"
                md += "   - \(s.targetLanguage): \(r.translatedText?.replacingOccurrences(of: "\n", with: " ") ?? "—")\n"
                if let n = r.translation?.notes { md += "   - note: \(n)\n" }
            }
            md += "\n"
        }
        return md
    }
}
