import CoreGraphics
import ImageIO
import Foundation
import PDFKit
import UniformTypeIdentifiers
import ZIPFoundation

public struct ImportReport: Sendable {
    public var added: [ComicPage] = []
    public var duplicates: [String] = []
    public var failures: [(name: String, reason: String)] = []
    public init() {}
    public var summary: String {
        var parts = ["Imported \(added.count) page\(added.count == 1 ? "" : "s")"]
        if !duplicates.isEmpty { parts.append("\(duplicates.count) duplicate\(duplicates.count == 1 ? "" : "s") skipped") }
        if !failures.isEmpty { parts.append("\(failures.count) failed") }
        return parts.joined(separator: ", ")
    }
}

public protocol ComicImportService: Sendable {
    func importItems(_ urls: [URL], into store: ProjectStore, at index: Int?, progress: (@Sendable (Double, String) -> Void)?) async -> ImportReport
}

/// Imports images, PDFs, CBZ/ZIP, CBR (via the system libarchive `bsdtar`) and folders.
public struct DefaultComicImportService: ComicImportService {
    public var pdfDPI: Double = 300
    public var allowDuplicates = false
    public init() {}

    struct Item { var name: String; var ext: String; var data: Data; var origin: String }

    public func importItems(_ urls: [URL], into store: ProjectStore, at index: Int? = nil,
                            progress: (@Sendable (Double, String) -> Void)? = nil) async -> ImportReport {
        var report = ImportReport()
        var items: [Item] = []
        for url in NaturalSort.sorted(urls, by: { $0.lastPathComponent }) {
            do { items += try collect(url) } catch {
                report.failures.append((url.lastPathComponent, error.localizedDescription))
            }
        }
        var known = Set(store.loadPages().map(\.originalHash))
        var insertAt = index
        for (i, item) in items.enumerated() {
            if Task.isCancelled { break }
            progress?(Double(i) / Double(max(1, items.count)), item.name)
            let hash = Hashing.sha256(item.data)
            if !allowDuplicates && known.contains(hash) { report.duplicates.append(item.name); continue }
            do {
                let page = try store.addPage(imageData: item.data, fileExtension: item.ext, name: item.name,
                                             importedFrom: item.origin, at: insertAt)
                known.insert(hash)
                report.added.append(page)
                if let k = insertAt { insertAt = k + 1 }
            } catch {
                report.failures.append((item.name, error.localizedDescription))
            }
        }
        progress?(1, "")
        return report
    }

    /// Imports raw image data (clipboard, drag from other apps).
    public func importData(_ data: Data, name: String, into store: ProjectStore) throws -> ComicPage {
        guard ImageIOHelper.pixelSize(data) != nil else { throw PanelLingoError.unsupportedFile(name) }
        let ext = ImageIOHelper.source(data).flatMap { CGImageSourceGetType($0) as String? }
            .flatMap { UTType($0)?.preferredFilenameExtension } ?? "png"
        return try store.addPage(imageData: data, fileExtension: ext, name: name, importedFrom: "pasteboard")
    }

    func collect(_ url: URL) throws -> [Item] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw PanelLingoError.unsupportedFile("\(url.lastPathComponent) not found")
        }
        if isDir.boolValue { return try collectFolder(url) }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return try collectPDF(url)
        case "cbz", "zip": return try collectZip(url)
        case "cbr", "rar": return try collectRar(url)
        default:
            guard ImageIOHelper.isImageFile(url) else { throw PanelLingoError.unsupportedFile(url.lastPathComponent) }
            let data = try Data(contentsOf: url)
            guard ImageIOHelper.pixelSize(data) != nil else { throw PanelLingoError.imageDecodeFailed(url.lastPathComponent) }
            return [Item(name: url.deletingPathExtension().lastPathComponent, ext: ext, data: data, origin: url.path)]
        }
    }

    func collectFolder(_ url: URL) throws -> [Item] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [URL] = []
        for case let f as URL in en where (try? f.resourceValues(forKeys: Set(keys)).isRegularFile) == true {
            let ext = f.pathExtension.lowercased()
            if ImageIOHelper.isImageFile(f) || ["pdf", "cbz", "zip", "cbr"].contains(ext) { files.append(f) }
        }
        let base = url.path
        return try NaturalSort.sorted(files, by: { String($0.path.dropFirst(base.count)) }).flatMap { try collect($0) }
    }

    func collectPDF(_ url: URL) throws -> [Item] {
        guard let doc = PDFDocument(url: url) else { throw PanelLingoError.corruptFile(url.lastPathComponent) }
        if doc.isLocked { throw PanelLingoError.unsupportedFile("\(url.lastPathComponent) is password protected") }
        var out: [Item] = []
        let stem = url.deletingPathExtension().lastPathComponent
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let img = Self.render(page, dpi: pdfDPI) else { continue }
            out.append(Item(name: "\(stem) p\(i + 1)", ext: "png", data: try ImageIOHelper.png(img), origin: "\(url.path)#\(i + 1)"))
        }
        if out.isEmpty { throw PanelLingoError.corruptFile("\(url.lastPathComponent) has no renderable pages") }
        return out
    }

    /// Renders a PDF page at the requested DPI (white background, respects page rotation).
    public static func render(_ page: PDFPage, dpi: Double) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let wPt = rotated ? box.height : box.width, hPt = rotated ? box.width : box.height
        let scale = dpi / 72
        let w = Int((wPt * scale).rounded()), h = Int((hPt * scale).rounded())
        guard w > 0, h > 0, w * h < 400_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: RGBAImage.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    func collectZip(_ url: URL) throws -> [Item] {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) } catch {
            throw PanelLingoError.corruptFile("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        // Entries are read straight into memory: nothing is written using archive-supplied paths,
        // so path traversal ("../") cannot escape the project.
        let entries = archive.filter { e in
            guard e.type == .file else { return false }
            let p = Self.sanitizedEntryPath(e.path)
            return !p.hasPrefix("__MACOSX") && !(p as NSString).lastPathComponent.hasPrefix(".")
                && ImageIOHelper.supportedExtensions.contains((p as NSString).pathExtension.lowercased())
        }
        var out: [Item] = []
        for e in NaturalSort.sorted(entries, by: { Self.sanitizedEntryPath($0.path) }) {
            guard e.uncompressedSize < 300_000_000 else { continue }
            var data = Data()
            do { _ = try archive.extract(e, skipCRC32: false) { data.append($0) } } catch { continue }
            let p = Self.sanitizedEntryPath(e.path)
            out.append(Item(name: ((p as NSString).lastPathComponent as NSString).deletingPathExtension,
                            ext: (p as NSString).pathExtension, data: data, origin: "\(url.path)!\(p)"))
        }
        if out.isEmpty { throw PanelLingoError.corruptFile("\(url.lastPathComponent) contains no readable images") }
        return out
    }

    func collectRar(_ url: URL) throws -> [Item] {
        let tar = URL(fileURLWithPath: "/usr/bin/bsdtar")
        guard FileManager.default.isExecutableFile(atPath: tar.path) else {
            throw PanelLingoError.unsupportedFile("CBR needs the system bsdtar, which is unavailable")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("panellingo-cbr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = tar
        // bsdtar refuses absolute paths and ".." components by default (no -P).
        p.arguments = ["-xf", url.path, "-C", tmp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw PanelLingoError.corruptFile("\(url.lastPathComponent) could not be extracted (RAR5 archives may be unsupported)") }
        let items = try collectFolder(tmp).map { var i = $0; i.origin = "\(url.path)!\(i.name)"; return i }
        if items.isEmpty { throw PanelLingoError.corruptFile("\(url.lastPathComponent) contains no readable images") }
        return items
    }

    /// Normalises an archive entry path: strips leading slashes, drive letters and `..` components.
    public static func sanitizedEntryPath(_ path: String) -> String {
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            .filter { $0 != ".." && $0 != "." && !$0.isEmpty && !$0.hasSuffix(":") }
        return parts.joined(separator: "/")
    }
}
