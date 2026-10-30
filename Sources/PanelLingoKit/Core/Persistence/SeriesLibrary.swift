import Foundation

// MARK: - Model

public enum SeriesRelationKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case sequel, prequel, spinOff, parentStory, sameUniverse, adaptation, alternateVersion, other
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .sequel: "Sequel"
        case .prequel: "Prequel"
        case .spinOff: "Spin-off"
        case .parentStory: "Parent story"
        case .sameUniverse: "Same universe"
        case .adaptation: "Adaptation"
        case .alternateVersion: "Alternate version"
        case .other: "Related"
        }
    }
    /// The relation as seen from the other series.
    public var inverse: SeriesRelationKind {
        switch self {
        case .sequel: .prequel
        case .prequel: .sequel
        case .spinOff: .parentStory
        case .parentStory: .spinOff
        default: self
        }
    }
    /// Sequels, spin-offs and shared universes usually share character names and terms.
    public var sharesGlossaryByDefault: Bool { self != .alternateVersion && self != .other && self != .adaptation }
}

/// Stored on series X as `(seriesID: Y, kind: K)` meaning "Y is X's K" — e.g. `(Y, .sequel)`:
/// Y is the sequel of X. `SeriesLibrary.link` stores the inverse on Y automatically.
public struct SeriesRelation: Codable, Hashable, Sendable {
    public var seriesID: String
    public var kind: SeriesRelationKind
    /// Use the related series' glossary (at lower priority) when translating this one.
    public var shareGlossary: Bool
    public init(seriesID: String, kind: SeriesRelationKind, shareGlossary: Bool? = nil) {
        self.seriesID = seriesID; self.kind = kind; self.shareGlossary = shareGlossary ?? kind.sharesGlossaryByDefault
    }
}

/// `series.json` inside a series folder. Every field is optional on disk so older/newer files load.
public struct SeriesInfo: Codable, Hashable, Identifiable, Sendable {
    public var formatVersion = 1
    public var id: String = "series-" + UUID().uuidString.prefix(8).lowercased()
    public var name: String
    public var alternateNames: [String] = []
    public var summary: String = ""
    /// Translation defaults for chapters of this series (nil = app defaults).
    public var sourceLanguage: String?
    public var targetLanguage: String?
    public var readingDirection: ReadingDirection?
    public var tone: TranslationTone?
    public var honorifics: HonorificPolicy?
    /// Characters, relationships and setting; sent to LLM translators for every chapter.
    public var storyContext: String = ""
    /// Series-wide glossary (chapters may add their own entries on top).
    public var glossary: [GlossaryEntry] = []
    public var related: [SeriesRelation] = []
    public var created = Date()
    public var modified = Date()

    public init(name: String) { self.name = name }

    enum CodingKeys: String, CodingKey {
        case formatVersion, id, name, alternateNames, summary, sourceLanguage, targetLanguage, readingDirection, tone, honorifics,
             storyContext, glossary, related, created, modified
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "series-" + UUID().uuidString.prefix(8).lowercased()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Series"
        alternateNames = try c.decodeIfPresent([String].self, forKey: .alternateNames) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        sourceLanguage = try c.decodeIfPresent(String.self, forKey: .sourceLanguage)
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage)
        readingDirection = try? c.decodeIfPresent(ReadingDirection.self, forKey: .readingDirection)
        tone = try? c.decodeIfPresent(TranslationTone.self, forKey: .tone)
        honorifics = try? c.decodeIfPresent(HonorificPolicy.self, forKey: .honorifics)
        storyContext = try c.decodeIfPresent(String.self, forKey: .storyContext) ?? ""
        glossary = try c.decodeIfPresent([GlossaryEntry].self, forKey: .glossary) ?? []
        related = try c.decodeIfPresent([SeriesRelation].self, forKey: .related) ?? []
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
    }

    /// True when `name` matches the series name or one of its alternate names.
    public func matches(_ other: String) -> Bool {
        let n = SeriesLibrary.normalize(other)
        return !n.isEmpty && ([name] + alternateNames).contains { SeriesLibrary.normalize($0) == n }
    }

    /// Project settings for a new chapter of this series.
    public func chapterSettings(base: ProjectSettings) -> ProjectSettings {
        var s = base
        if let v = sourceLanguage { s.sourceLanguage = v }
        if let v = targetLanguage { s.targetLanguage = v }
        if let v = readingDirection { s.readingDirection = v }
        if let v = tone { s.tone = v }
        if let v = honorifics { s.honorifics = v }
        return s
    }
}

public struct SeriesEntry: Identifiable, Hashable, Sendable {
    public var info: SeriesInfo
    public var folder: URL
    /// Chapters in reading order.
    public var chapters: [ChapterSummary]
    public init(info: SeriesInfo, folder: URL, chapters: [ChapterSummary]) { self.info = info; self.folder = folder; self.chapters = chapters }
    public var id: String { info.id }
    public var translatedCount: Int { chapters.filter { $0.status == .translated || $0.status == .needsReview }.count }
    public var coverURL: URL? { chapters.first(where: { $0.coverURL != nil })?.coverURL }
    public var modified: Date { chapters.map(\.modified).max() ?? info.modified }
}

public struct LibrarySnapshot: Sendable {
    public var series: [SeriesEntry] = []
    /// Chapters not inside any series folder.
    public var unsorted: [ChapterSummary] = []
    public init(series: [SeriesEntry] = [], unsorted: [ChapterSummary] = []) { self.series = series; self.unsorted = unsorted }

    public var allChapters: [ChapterSummary] { series.flatMap(\.chapters) + unsorted }
    public func series(id: String) -> SeriesEntry? { series.first { $0.id == id } }
    public func series(containing chapter: URL) -> SeriesEntry? {
        series.first { $0.chapters.contains { $0.url.standardizedFileURL == chapter.standardizedFileURL } }
    }
    public func matchSeries(named name: String) -> SeriesEntry? { series.first { $0.info.matches(name) } }
}

// MARK: - Library on disk

/// Library layout:
/// ```
/// <library>/
///   <Series Name>/
///     series.json                 SeriesInfo (name, defaults, glossary, related series)
///     <chapter>.panellingo         one project per chapter
///   <chapter>.panellingo           unsorted chapter (no series)
/// ```
public struct SeriesLibrary: Sendable {
    public static let infoFileName = "series.json"
    public let root: URL
    public init(root: URL) { self.root = root }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Scan

    /// Reads all series folders and chapters. `extra` adds projects stored elsewhere (recent documents) as unsorted.
    public func scan(extra: [URL] = []) -> LibrarySnapshot {
        let fm = FileManager.default
        var snap = LibrarySnapshot()
        var seen = Set<String>()
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for u in items {
            if u.pathExtension == ProjectStore.fileExtension {
                if let c = ChapterLibrary.summary(u) { snap.unsorted.append(c); seen.insert(u.standardizedFileURL.path) }
                continue
            }
            guard (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let chapters = ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == ProjectStore.fileExtension }
            let info = loadInfo(folder: u)
            // A folder is a series when it has series.json or contains chapters.
            guard info != nil || !chapters.isEmpty else { continue }
            var summaries = chapters.compactMap(ChapterLibrary.summary).sorted(by: ChapterLibrary.chapterOrder)
            for i in summaries.indices { seen.insert(summaries[i].url.standardizedFileURL.path) }
            let resolved = info ?? SeriesInfo(name: u.lastPathComponent)
            for i in summaries.indices { summaries[i].series = resolved.name }
            snap.series.append(SeriesEntry(info: resolved, folder: u, chapters: summaries))
        }
        for e in extra where e.pathExtension == ProjectStore.fileExtension && !seen.contains(e.standardizedFileURL.path)
            && fm.fileExists(atPath: e.path) && !e.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") {
            if let c = ChapterLibrary.summary(e) { snap.unsorted.append(c); seen.insert(e.standardizedFileURL.path) }
        }
        snap.series.sort { $0.info.name.localizedStandardCompare($1.info.name) == .orderedAscending }
        snap.unsorted.sort(by: ChapterLibrary.chapterOrder)
        return snap
    }

    public func loadInfo(folder: URL) -> SeriesInfo? {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent(Self.infoFileName)) else { return nil }
        return try? FileIO.decoder.decode(SeriesInfo.self, from: d)
    }

    public func saveInfo(_ info: SeriesInfo, folder: URL) throws {
        var i = info
        i.modified = Date()
        try FileIO.writeAtomically(FileIO.encoder.encode(i), to: folder.appendingPathComponent(Self.infoFileName))
    }

    /// Series folder that contains `chapter`, if any.
    public func seriesFolder(containing chapter: URL) -> URL? {
        // Compare resolved paths: /private/tmp vs /tmp style aliases must not matter.
        let parent = chapter.deletingLastPathComponent().resolvingSymlinksInPath()
        let rootPath = root.resolvingSymlinksInPath().path
        guard parent.path != rootPath else { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: parent.appendingPathComponent(Self.infoFileName).path) { return parent }
        return parent.deletingLastPathComponent().path == rootPath ? parent : nil
    }

    // MARK: Series CRUD

    @discardableResult
    public func createSeries(_ info: SeriesInfo) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = FileIO.sanitizeFileName(info.name, fallback: "Series")
        var folder = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = root.appendingPathComponent("\(base) \(n)", isDirectory: true); n += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try saveInfo(info, folder: folder)
        return folder
    }

    /// Saves edits; renames the folder to match a new name when possible. Returns the (possibly new) folder.
    @discardableResult
    public func updateSeries(_ info: SeriesInfo, folder: URL) throws -> URL {
        var target = folder
        let wanted = FileIO.sanitizeFileName(info.name, fallback: folder.lastPathComponent)
        if wanted != folder.lastPathComponent {
            let candidate = folder.deletingLastPathComponent().appendingPathComponent(wanted, isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                try FileManager.default.moveItem(at: folder, to: candidate)
                target = candidate
            }
        }
        try saveInfo(info, folder: target)
        // Keep each chapter's cached series name in sync.
        for c in (try? FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? [] where c.pathExtension == ProjectStore.fileExtension {
            try? ProjectStore.open(c).updateManifest { $0.series = info.name }
        }
        return target
    }

    /// Moves chapters out of a series folder to the library root and removes the empty folder's
    /// `series.json` link from related series. Returns the moved chapter URLs. The caller trashes `folder`.
    public func dissolveSeries(folder: URL, snapshot: LibrarySnapshot) throws -> [URL] {
        var moved: [URL] = []
        for c in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where c.pathExtension == ProjectStore.fileExtension {
            moved.append(try moveChapter(c, toSeriesFolder: nil, seriesName: nil))
        }
        try removeRelations(ofSeriesIn: folder, snapshot: snapshot)
        return moved
    }

    /// Removes links pointing at the series in `folder` from every other series.
    public func removeRelations(ofSeriesIn folder: URL, snapshot: LibrarySnapshot) throws {
        guard let info = loadInfo(folder: folder) else { return }
        for other in snapshot.series where other.info.related.contains(where: { $0.seriesID == info.id }) {
            var o = other.info
            o.related.removeAll { $0.seriesID == info.id }
            try saveInfo(o, folder: other.folder)
        }
    }

    // MARK: Chapters

    /// Moves a chapter package into a series folder (or to the root when `nil`). Returns the new URL.
    @discardableResult
    public func moveChapter(_ chapter: URL, toSeriesFolder folder: URL?, seriesName: String?) throws -> URL {
        let destDir = folder ?? root
        var dest = destDir.appendingPathComponent(chapter.lastPathComponent)
        if dest.standardizedFileURL == chapter.standardizedFileURL { return chapter }
        let stem = chapter.deletingPathExtension().lastPathComponent
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = destDir.appendingPathComponent("\(stem) \(n).\(ProjectStore.fileExtension)"); n += 1
        }
        try FileManager.default.moveItem(at: chapter, to: dest)
        try ProjectStore.open(dest).updateManifest { $0.series = seriesName }
        return dest
    }

    /// Unique URL for a new chapter package in `folder` (or the root).
    public func newChapterURL(name: String, in folder: URL?) throws -> URL {
        let dir = folder ?? root
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = FileIO.sanitizeFileName(name, fallback: "Chapter")
        var url = dir.appendingPathComponent("\(base).\(ProjectStore.fileExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).\(ProjectStore.fileExtension)"); n += 1
        }
        return url
    }

    // MARK: Relations

    /// Records "`b` is `a`'s `kind`" on `a`, and the inverse ("`a` is `b`'s `kind.inverse`") on `b`.
    public func link(_ a: SeriesEntry, _ b: SeriesEntry, kind: SeriesRelationKind, shareGlossary: Bool? = nil) throws {
        guard a.id != b.id else { return }
        var ai = a.info, bi = b.info
        ai.related.removeAll { $0.seriesID == b.id }
        bi.related.removeAll { $0.seriesID == a.id }
        ai.related.append(SeriesRelation(seriesID: b.id, kind: kind, shareGlossary: shareGlossary))
        bi.related.append(SeriesRelation(seriesID: a.id, kind: kind.inverse, shareGlossary: shareGlossary))
        try saveInfo(ai, folder: a.folder)
        try saveInfo(bi, folder: b.folder)
    }

    public func unlink(_ a: SeriesEntry, _ b: SeriesEntry) throws {
        var ai = a.info, bi = b.info
        ai.related.removeAll { $0.seriesID == b.id }
        bi.related.removeAll { $0.seriesID == a.id }
        try saveInfo(ai, folder: a.folder)
        try saveInfo(bi, folder: b.folder)
    }

    // MARK: Glossary / context

    /// Chapter glossary, then the series glossary, then glossaries of related series that share theirs.
    /// Earlier sources win when the same original term appears twice.
    public static func effectiveGlossary(chapter: [GlossaryEntry], series: SeriesEntry?, snapshot: LibrarySnapshot) -> [GlossaryEntry] {
        var sources = [chapter]
        if let s = series {
            sources.append(s.info.glossary)
            for r in s.info.related where r.shareGlossary {
                if let other = snapshot.series(id: r.seriesID) { sources.append(other.info.glossary) }
            }
        }
        var seen = Set<String>()
        var out: [GlossaryEntry] = []
        for src in sources {
            for e in src where !e.original.isEmpty && seen.insert(normalize(e.original)).inserted { out.append(e) }
        }
        return out
    }

    /// Series story context + related-series notes + chapter-specific context, for the translator.
    public static func effectiveStoryContext(chapter: String, series: SeriesEntry?, snapshot: LibrarySnapshot) -> String {
        var parts: [String] = []
        if let s = series {
            if !s.info.storyContext.isEmpty { parts.append("Series “\(s.info.name)”: \(s.info.storyContext)") }
            let rel = s.info.related.compactMap { r in snapshot.series(id: r.seriesID).map { "\(r.kind.displayName): \($0.info.name)" } }
            if !rel.isEmpty { parts.append("Related series — " + rel.joined(separator: "; ")) }
        }
        if !chapter.isEmpty { parts.append(chapter) }
        return parts.joined(separator: "\n")
    }
}
