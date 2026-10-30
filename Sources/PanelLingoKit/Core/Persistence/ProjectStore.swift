import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

/// File-package backed project storage (`*.panellingo`).
///
/// Layout:
/// ```
/// MyComic.panellingo/
///   manifest.json  settings.json  glossary.json
///   originals/<page>.<ext>          untouched source bytes (never modified)
///   pages/<page>.json               regions, OCR, translations, styling, status
///   masks/<page>/<region>.png       text-removal masks (8-bit)
///   cleaned/<page>/<region>.png     cleaned patches (only masked pixels differ from the original)
///   previews/<page>.jpg             thumbnails
/// ```
/// Every write is atomic (temp file + rename). API credentials are never stored here.
public final class ProjectStore: @unchecked Sendable {
    public static let fileExtension = "panellingo"
    public static let typeIdentifier = "app.panellingo.project"

    public let url: URL
    public private(set) var manifest: ProjectManifest
    public private(set) var settings: ProjectSettings
    public private(set) var glossary: [GlossaryEntry]

    private let lock = NSRecursiveLock()
    private var imageCache: [String: CGImage] = [:]
    private var imageCacheOrder: [String] = []
    private let imageCacheLimit = 3

    // MARK: Create / open

    public static func create(at url: URL, title: String, settings: ProjectSettings = ProjectSettings()) throws -> ProjectStore {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { throw PanelLingoError.projectFormat("\(url.lastPathComponent) already exists") }
        for dir in ["originals", "pages", "masks", "cleaned", "previews"] {
            try fm.createDirectory(at: url.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let store = ProjectStore(url: url, manifest: ProjectManifest(title: title), settings: settings, glossary: [])
        try store.saveManifest()
        try store.saveSettings(settings)
        try store.saveGlossary([])
        return store
    }

    public static func open(_ url: URL) throws -> ProjectStore {
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw PanelLingoError.projectFormat("missing manifest.json")
        }
        var manifest: ProjectManifest
        do { manifest = try FileIO.decoder.decode(ProjectManifest.self, from: data) } catch {
            throw PanelLingoError.projectFormat("manifest.json is invalid: \(error.localizedDescription)")
        }
        if manifest.formatVersion > ProjectManifest.currentFormatVersion {
            throw PanelLingoError.projectFormat("created by a newer PanelLingo (format \(manifest.formatVersion))")
        }
        manifest = ProjectMigration.migrate(manifest)
        let settings = (try? Data(contentsOf: url.appendingPathComponent("settings.json")))
            .flatMap { try? FileIO.decoder.decode(ProjectSettings.self, from: $0) } ?? ProjectSettings()
        let glossary = (try? Data(contentsOf: url.appendingPathComponent("glossary.json")))
            .flatMap { try? FileIO.decoder.decode([GlossaryEntry].self, from: $0) } ?? []
        for dir in ["originals", "pages", "masks", "cleaned", "previews"] {
            try? FileManager.default.createDirectory(at: url.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        return ProjectStore(url: url, manifest: manifest, settings: settings, glossary: glossary)
    }

    private init(url: URL, manifest: ProjectManifest, settings: ProjectSettings, glossary: [GlossaryEntry]) {
        self.url = url; self.manifest = manifest; self.settings = settings; self.glossary = glossary
    }

    // MARK: Paths

    public func originalURL(_ page: ComicPage) -> URL { url.appendingPathComponent("originals/\(page.originalFileName)") }
    func pageURL(_ id: String) -> URL { url.appendingPathComponent("pages/\(id).json") }
    func maskURL(_ pageID: String, _ regionID: String) -> URL { url.appendingPathComponent("masks/\(pageID)/\(regionID).png") }
    func patchURL(_ pageID: String, _ regionID: String) -> URL { url.appendingPathComponent("cleaned/\(pageID)/\(regionID).png") }
    public func previewURL(_ id: String) -> URL { url.appendingPathComponent("previews/\(id).jpg") }

    // MARK: Manifest, settings, glossary

    public func saveManifest() throws {
        lock.lock(); defer { lock.unlock() }
        manifest.modified = Date()
        try FileIO.writeAtomically(FileIO.encoder.encode(manifest), to: url.appendingPathComponent("manifest.json"))
    }

    public func updateManifest(_ body: (inout ProjectManifest) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        body(&manifest)
        try saveManifest()
    }

    public func saveSettings(_ s: ProjectSettings) throws {
        lock.lock(); defer { lock.unlock() }
        settings = s
        try FileIO.writeAtomically(FileIO.encoder.encode(s), to: url.appendingPathComponent("settings.json"))
    }

    public func saveGlossary(_ g: [GlossaryEntry]) throws {
        lock.lock(); defer { lock.unlock() }
        glossary = g
        try FileIO.writeAtomically(FileIO.encoder.encode(g), to: url.appendingPathComponent("glossary.json"))
    }

    // MARK: Pages

    public func loadPages() -> [ComicPage] {
        manifest.pageIDs.compactMap { loadPage($0) }
    }

    public func loadPage(_ id: String) -> ComicPage? {
        guard let data = try? Data(contentsOf: pageURL(id)) else { return nil }
        do { return try FileIO.decoder.decode(ComicPage.self, from: data) } catch {
            Log.storage.error("page \(id, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func savePage(_ page: ComicPage) throws {
        try FileIO.writeAtomically(FileIO.encoder.encode(page), to: pageURL(page.id))
    }

    /// Adds a page from raw image bytes. The bytes are stored verbatim.
    @discardableResult
    public func addPage(imageData: Data, fileExtension: String, name: String, importedFrom: String?, at index: Int? = nil) throws -> ComicPage {
        guard let (w, h) = ImageIOHelper.pixelSize(imageData) else {
            throw PanelLingoError.imageDecodeFailed(name)
        }
        let id = ComicPage.makeID()
        let ext = fileExtension.lowercased().isEmpty ? "png" : fileExtension.lowercased()
        let fileName = "\(id).\(ext)"
        var page = ComicPage(id: id, name: name, originalFileName: fileName, originalHash: Hashing.sha256(imageData),
                             pixelWidth: w, pixelHeight: h, importedFrom: importedFrom)
        // Images with EXIF rotation are normalised once to an upright PNG so pixel coordinates are unambiguous.
        if let src = ImageIOHelper.source(imageData),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let o = p[kCGImagePropertyOrientation] as? UInt32, o != 1 {
            let upright = try ImageIOHelper.cgImage(from: imageData)
            page.originalFileName = "\(id).png"
            page.pixelWidth = upright.width; page.pixelHeight = upright.height
            try FileIO.writeAtomically(ImageIOHelper.png(upright), to: originalURL(page))
        } else {
            try FileIO.writeAtomically(imageData, to: originalURL(page))
        }
        try savePage(page)
        writePreview(for: page, data: imageData)
        try updateManifest { m in
            if let i = index, i <= m.pageIDs.count { m.pageIDs.insert(id, at: i) } else { m.pageIDs.append(id) }
        }
        return page
    }

    public func removePage(_ id: String) throws {
        try updateManifest { $0.pageIDs.removeAll { $0 == id } }
        let fm = FileManager.default
        if let page = loadPage(id) { try? fm.removeItem(at: originalURL(page)) }
        for u in [pageURL(id), previewURL(id), url.appendingPathComponent("masks/\(id)"), url.appendingPathComponent("cleaned/\(id)")] {
            try? fm.removeItem(at: u)
        }
        lock.lock(); imageCache[id] = nil; lock.unlock()
    }

    public func reorderPages(_ ids: [String]) throws {
        try updateManifest { $0.pageIDs = ids }
    }

    public func hasOriginal(hash: String) -> Bool {
        loadPages().contains { $0.originalHash == hash }
    }

    // MARK: Images

    public func originalData(_ page: ComicPage) throws -> Data {
        try Data(contentsOf: originalURL(page), options: .mappedIfSafe)
    }

    /// Full-resolution original image (small LRU cache so chapters are never fully resident).
    public func originalImage(_ page: ComicPage) throws -> CGImage {
        lock.lock()
        if let img = imageCache[page.id] {
            imageCacheOrder.removeAll { $0 == page.id }; imageCacheOrder.append(page.id)
            lock.unlock(); return img
        }
        lock.unlock()
        let img = try ImageIOHelper.cgImage(contentsOf: originalURL(page))
        lock.lock()
        imageCache[page.id] = img
        imageCacheOrder.append(page.id)
        while imageCacheOrder.count > imageCacheLimit { imageCache[imageCacheOrder.removeFirst()] = nil }
        lock.unlock()
        return img
    }

    public func writePreview(for page: ComicPage, data: Data? = nil, image: CGImage? = nil) {
        let thumb: CGImage?
        if let image {
            thumb = (try? ImageIOHelper.png(image)).flatMap { ImageIOHelper.thumbnail($0, maxPixel: 360) }
        } else {
            thumb = (data ?? (try? originalData(page))).flatMap { ImageIOHelper.thumbnail($0, maxPixel: 360) }
        }
        if let thumb, let jpg = try? ImageIOHelper.encode(thumb, type: .jpeg, quality: 0.8) {
            try? FileIO.writeAtomically(jpg, to: previewURL(page.id))
        }
    }

    // MARK: Cleanup layers

    public func loadMask(pageID: String, regionID: String) -> BitMask? {
        guard let data = try? Data(contentsOf: maskURL(pageID, regionID)),
              let img = try? ImageIOHelper.cgImage(from: data) else { return nil }
        return BitMask(gray: GrayImage(img))
    }

    public func saveMask(_ mask: BitMask, pageID: String, regionID: String) throws {
        guard let img = mask.grayImage().cgImage() else { return }
        try FileIO.writeAtomically(ImageIOHelper.png(img), to: maskURL(pageID, regionID))
    }

    public func loadPatch(pageID: String, regionID: String) -> CGImage? {
        guard let data = try? Data(contentsOf: patchURL(pageID, regionID)) else { return nil }
        return try? ImageIOHelper.cgImage(from: data)
    }

    public func savePatch(_ patch: CGImage, pageID: String, regionID: String) throws {
        try FileIO.writeAtomically(ImageIOHelper.png(patch), to: patchURL(pageID, regionID))
    }

    public func removePatch(pageID: String, regionID: String) {
        try? FileManager.default.removeItem(at: patchURL(pageID, regionID))
    }

    public func removeRegionLayers(pageID: String, regionID: String) {
        try? FileManager.default.removeItem(at: maskURL(pageID, regionID))
        removePatch(pageID: pageID, regionID: regionID)
    }

    public func maskData(pageID: String, regionID: String) -> Data? { try? Data(contentsOf: maskURL(pageID, regionID)) }
    public func patchData(pageID: String, regionID: String) -> Data? { try? Data(contentsOf: patchURL(pageID, regionID)) }

    /// Restores raw layer bytes (used by undo).
    public func restoreLayers(pageID: String, regionID: String, mask: Data?, patch: Data?) {
        if let mask { try? FileIO.writeAtomically(mask, to: maskURL(pageID, regionID)) } else { try? FileManager.default.removeItem(at: maskURL(pageID, regionID)) }
        if let patch { try? FileIO.writeAtomically(patch, to: patchURL(pageID, regionID)) } else { removePatch(pageID: pageID, regionID: regionID) }
    }

    // MARK: Save As

    /// Copies the package to a new location and returns a store for it.
    public func duplicate(to newURL: URL, title: String? = nil) throws -> ProjectStore {
        if FileManager.default.fileExists(atPath: newURL.path) { try FileManager.default.removeItem(at: newURL) }
        try FileManager.default.copyItem(at: url, to: newURL)
        let s = try ProjectStore.open(newURL)
        if let title { try s.updateManifest { $0.title = title } }
        return s
    }
}

public enum ProjectMigration {
    /// Upgrades older manifests in place. Version 1 is the first public format.
    public static func migrate(_ m: ProjectManifest) -> ProjectManifest {
        var m = m
        if m.formatVersion < 1 { m.formatVersion = 1 }
        return m
    }
}
