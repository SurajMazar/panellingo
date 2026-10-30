import Foundation

/// One chapter (= one `.panellingo` project) as shown in the library.
public struct ChapterSummary: Identifiable, Hashable, Sendable {
    public enum Status: String, Sendable, CaseIterable {
        case empty, notStarted, inProgress, needsReview, translated, failed
        public var displayName: String {
            switch self {
            case .empty: "No pages"
            case .notStarted: "Not translated"
            case .inProgress: "In progress"
            case .needsReview: "Needs review"
            case .translated: "Translated"
            case .failed: "Failed"
            }
        }
    }

    public var url: URL
    public var title: String
    public var series: String?
    public var chapter: String?
    public var pageCount: Int
    /// Pages with every stage done (completed or needs-review).
    public var translatedPages: Int
    public var reviewPages: Int
    public var failedPages: Int
    public var sourceLanguage: String
    public var targetLanguage: String
    public var modified: Date
    public var coverURL: URL?
    public var id: String { url.path }

    public var status: Status {
        if pageCount == 0 { return .empty }
        if failedPages > 0 { return .failed }
        if translatedPages == pageCount { return reviewPages > 0 ? .needsReview : .translated }
        return translatedPages == 0 ? .notStarted : .inProgress
    }

    public var progress: Double { pageCount == 0 ? 0 : Double(translatedPages) / Double(pageCount) }

    /// "Series" for grouping; chapters without one are grouped under their own title.
    public var seriesKey: String { series?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Other chapters" }

    public var displayTitle: String {
        if let c = chapter?.nilIfEmpty { return "Chapter \(c)" }
        return title
    }
}

public enum ChapterLibrary {
    /// Reads every `.panellingo` package in `folder` (non-recursive, plus one level of sub-folders)
    /// and any `extra` project URLs (e.g. recent documents stored elsewhere).
    public static func scan(folder: URL, extra: [URL] = []) -> [ChapterSummary] {
        let fm = FileManager.default
        var urls: [URL] = []
        func collect(_ dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for u in items {
                if u.pathExtension == ProjectStore.fileExtension { urls.append(u) }
                else if depth > 0, (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { collect(u, depth: depth - 1) }
            }
        }
        collect(folder, depth: 1)
        for e in extra where e.pathExtension == ProjectStore.fileExtension && fm.fileExists(atPath: e.path) {
            if !urls.contains(where: { $0.standardizedFileURL == e.standardizedFileURL }) { urls.append(e) }
        }
        return urls.compactMap(summary)
    }

    public static func summary(_ url: URL) -> ChapterSummary? {
        guard let store = try? ProjectStore.open(url) else { return nil }
        let pages = store.loadPages()
        let allStages = Set(PipelineStage.allCases)
        let done = pages.filter { allStages.isSubset(of: $0.completedStages) }
        let modified = (try? url.appendingPathComponent("manifest.json").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? store.manifest.modified
        let latestPage = pages.compactMap { p in
            try? url.appendingPathComponent("pages/\(p.id).json").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
        return ChapterSummary(
            url: url, title: store.manifest.title, series: store.manifest.series, chapter: store.manifest.chapter,
            pageCount: pages.count, translatedPages: done.count,
            reviewPages: done.filter { $0.status == .needsReview || $0.needsReviewCount > 0 }.count,
            failedPages: pages.filter { $0.status == .failed }.count,
            sourceLanguage: store.settings.sourceLanguage, targetLanguage: store.settings.targetLanguage,
            modified: max(modified, latestPage ?? modified),
            coverURL: pages.first.map { store.previewURL($0.id) })
    }

    /// Orders chapters within a series numerically ("2" < "10" < "10.5").
    public static func chapterOrder(_ a: ChapterSummary, _ b: ChapterSummary) -> Bool {
        switch (a.chapter.flatMap(Double.init), b.chapter.flatMap(Double.init)) {
        case let (x?, y?) where x != y: return x < y
        default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    private static let chapterPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[\s_\-\.\[\(])(?:chapter|chap|ch|episode|ep|vol\.?\s*\d+\s*ch)\.?[\s_\-]*(\d+(?:\.\d+)?)|第\s*(\d+(?:\.\d+)?)\s*[話话章]|제\s*(\d+)\s*화"#)
    private static let trailingNumber = try! NSRegularExpression(pattern: #"^(.*?\D)[\s_\-#]*(\d+(?:\.\d+)?)\s*$"#)

    /// Guesses series and chapter from a file or folder name, e.g.
    /// "regressed-warriors-female-dominance-raw-chapter-108" → ("Regressed Warriors Female Dominance", "108").
    public static func guess(from rawName: String) -> (series: String?, chapter: String?) {
        let name = (rawName as NSString).deletingPathExtension
        let ns = name as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let m = chapterPattern.firstMatch(in: name, range: full) {
            let num = (1...3).compactMap { i -> String? in
                let r = m.range(at: i); return r.location == NSNotFound ? nil : ns.substring(with: r)
            }.first
            let series = tidySeries(ns.substring(to: m.range.location))
            return (series, num.map(trimNumber))
        }
        if let m = trailingNumber.firstMatch(in: name, range: full) {
            let series = tidySeries(ns.substring(with: m.range(at: 1)))
            return (series, trimNumber(ns.substring(with: m.range(at: 2))))
        }
        return (tidySeries(name), nil)
    }

    static func trimNumber(_ s: String) -> String {
        guard let d = Double(s) else { return s }
        return d == d.rounded() ? String(Int(d)) : String(d)
    }

    static func tidySeries(_ s: String) -> String? {
        var t = s.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        t = t.replacingOccurrences(of: #"(?i)\b(raw|raws|eng|english|scan|scans)\b"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[\[\]\(\)]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !t.isEmpty else { return nil }
        // Title-case all-lowercase slugs; leave mixed case / CJK untouched.
        return t == t.lowercased() && t.range(of: "[a-z]", options: .regularExpression) != nil ? t.capitalized : t
    }

    /// Splits dropped/chosen items into chapters: each PDF, archive or folder is one chapter;
    /// loose image files together form one chapter.
    public static func groupIntoChapters(_ urls: [URL]) -> [(name: String, items: [URL])] {
        var chapters: [(String, [URL])] = []
        var loose: [URL] = []
        for u in NaturalSort.sorted(urls, by: { $0.lastPathComponent }) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue || ["pdf", "cbz", "zip", "cbr", "rar"].contains(u.pathExtension.lowercased()) {
                chapters.append((u.deletingPathExtension().lastPathComponent, [u]))
            } else {
                loose.append(u)
            }
        }
        if !loose.isEmpty {
            let parent = loose[0].deletingLastPathComponent().lastPathComponent
            chapters.append((parent.isEmpty ? loose[0].deletingPathExtension().lastPathComponent : parent, loose))
        }
        return chapters
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
