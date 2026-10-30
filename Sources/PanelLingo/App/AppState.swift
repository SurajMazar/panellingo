import AppKit
import Observation
import PanelLingoKit
import SwiftUI
import UniformTypeIdentifiers

enum ComparisonMode: String, CaseIterable, Identifiable {
    case none, split, sideBySide
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: "Single View"
        case .split: "Split Compare"
        case .sideBySide: "Side by Side"
        }
    }
}

enum CanvasTool: String, CaseIterable, Identifiable {
    case select, rectangle, polygon, brush, eraser, readingOrder
    var id: String { rawValue }
    var label: String {
        switch self {
        case .select: "Select"
        case .rectangle: "Draw Rectangle Region"
        case .polygon: "Draw Polygon Region"
        case .brush: "Mask Brush"
        case .eraser: "Mask Eraser"
        case .readingOrder: "Reading Order"
        }
    }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle.dashed"
        case .polygon: "skew"
        case .brush: "paintbrush.pointed"
        case .eraser: "eraser"
        case .readingOrder: "list.number"
        }
    }
}

struct AlertItem: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct ConsentRequest: Identifiable {
    let id = UUID()
    var provider: ProviderKind
    var characters: Int
    var includesImages: Bool
    var proceed: () -> Void
}

/// Canvas viewport state shared between the toolbar, menu commands and the scroll view.
@MainActor @Observable
final class CanvasModel {
    enum Command: Equatable { case fitPage, fitWidth, actualSize, zoomIn, zoomOut }
    var magnification: Double = 1
    var command: (Command, UUID)?
    var splitPosition: Double = 0.5
    func send(_ c: Command) { command = (c, UUID()) }
}

@MainActor @Observable
final class AppState {
    let settings = AppSettings.shared
    let canvas = CanvasModel()

    // Project
    var store: ProjectStore?
    var projectTitle = ""
    var pages: [ComicPage] = []
    var projectSettings = ProjectSettings()
    var glossary: [GlossaryEntry] = []

    // Selection & tools
    var selectedPageID: String? { didSet { if oldValue != selectedPageID { pageChanged() } } }
    var selectedRegionIDs: Set<String> = []
    var displayMode: RenderMode = .translated { didSet { scheduleRender() } }
    var comparison: ComparisonMode = .none
    var tool: CanvasTool = .select { didSet { if tool == .readingOrder { readingOrderSequence = [] } } }
    var brushSize = 14.0
    var readingOrderSequence: [String] = []
    var showOverlays = true
    var editingRegionID: String?
    var searchText = ""

    // Rendered layers for the current page
    var originalImage: CGImage?
    var cleanedImage: CGImage?
    var translatedImage: CGImage?
    private var renderTask: Task<Void, Never>?
    private var renderGeneration = 0

    // Processing
    var pageTasks: [String: Task<Void, Never>] = [:]
    var batch: BatchQueue?
    var batchSnapshot: BatchQueue.Snapshot?
    var importProgress: (Double, String)?
    var alternatives: [String: [TranslationRecord]] = [:]
    private var sessionConsent: Set<ProviderKind> = []

    // Library
    var showLibrary = false
    var library = LibrarySnapshot()
    var libraryLoading = false
    /// nil = all series; a series ID; or `AppState.unsortedID`.
    var librarySelection: String?
    static let unsortedID = "__unsorted__"
    var chapters: [ChapterSummary] { library.allChapters }
    var seriesLibrary: SeriesLibrary { SeriesLibrary(root: settings.projectLocation) }
    /// Series of the open chapter.
    var currentSeries: SeriesEntry? { store.flatMap { library.series(containing: $0.url) } }

    // Presentation
    var alert: AlertItem?
    var consent: ConsentRequest?
    var toast: String?
    var showOnboarding = false
    var showExport = false
    var showBatch = false
    var showGlossary = false
    var showProjectSettings = false
    weak var undoManager: UndoManager?

    init() {
        showOnboarding = !settings.stored.onboardingDone
        if let path = settings.stored.lastProjectPath, FileManager.default.fileExists(atPath: path) {
            try? openProject(URL(fileURLWithPath: path))
        }
    }

    /// Launch arguments for demos and automated UI checks:
    /// `--skip-onboarding`, `--sample`, `--open <path>`, `--provider <kind>`, `--model <name>`,
    /// `--translate`, `--mode original|cleaned|translated`, `--compare split|side`, `--select-first-region`.
    func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        func value(_ k: String) -> String? { args.firstIndex(of: k).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        if args.contains("--skip-onboarding") { showOnboarding = false }
        if args.contains("--library") { showLibrary = true }
        if args.contains("--organize-library") { organizeUnsorted() }
        if let name = value("--series") {
            showLibrary = true
            Task {
                for _ in 0..<40 where self.library.matchSeries(named: name) == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                self.librarySelection = self.library.matchSeries(named: name)?.id
            }
        }
        let addChapters = args.indices.filter { args[$0] == "--add-chapter" && args.indices.contains($0 + 1) }.map { URL(fileURLWithPath: args[$0 + 1]) }
        if !addChapters.isEmpty { importAsChapters(addChapters) }
        if args.contains("--sample") { openSample() }
        if let p = value("--open") {
            let url = URL(fileURLWithPath: p)
            if url.pathExtension == ProjectStore.fileExtension { try? openProject(url) } else { importItems([url]) }
        }
        if let k = value("--provider").flatMap(ProviderKind.init(rawValue:)) {
            updateProjectSettings { $0.translationProvider = k; if let m = value("--model") { $0.translationModel = m } }
        }
        if let m = value("--mode").flatMap(RenderMode.init(rawValue:)) { displayMode = m }
        if let c = value("--compare") { comparison = c == "split" ? .split : c == "side" ? .sideBySide : .none }
        if args.contains("--translate") {
            sessionConsent.formUnion(ProviderKind.allCases.filter { _ in args.contains("--accept-cloud") })
            Task { try? await Task.sleep(nanoseconds: 800_000_000); self.translateCurrentPage() }
        }
        if args.contains("--select-first-region") {
            Task {
                while self.pageTasks.isEmpty == false || self.currentPage?.regions.isEmpty != false { try? await Task.sleep(nanoseconds: 500_000_000) }
                self.selectedRegionIDs = Set(self.currentPage?.orderedRegions.prefix(1).map(\.id) ?? [])
            }
        }
    }

    // MARK: - Derived

    var hasProject: Bool { store != nil }
    var currentPageIndex: Int? { pages.firstIndex { $0.id == selectedPageID } }
    var currentPage: ComicPage? { currentPageIndex.map { pages[$0] } }
    var selectedRegion: TextRegion? {
        guard selectedRegionIDs.count == 1, let id = selectedRegionIDs.first else { return nil }
        return currentPage?.regions.first { $0.id == id }
    }
    var isProcessingCurrentPage: Bool { selectedPageID.map { pageTasks[$0] != nil } ?? false }

    var pipelineOptions: PipelineOptions {
        // Chapter glossary/context first, then the series', then related series that share theirs.
        var ps = projectSettings
        ps.storyContext = SeriesLibrary.effectiveStoryContext(chapter: projectSettings.storyContext, series: currentSeries, snapshot: library)
        return PipelineOptions(settings: ps, glossary: SeriesLibrary.effectiveGlossary(chapter: glossary, series: currentSeries, snapshot: library),
                        providers: settings.providerMap,
                        privacy: settings.stored.privacy, processing: settings.stored.processing,
                        includePageImage: settings.stored.includePageImage)
    }

    func pageIndex(_ id: String) -> Int? { pages.firstIndex { $0.id == id } }

    // MARK: - Project lifecycle

    func openProject(_ url: URL) throws {
        let s = try ProjectStore.open(url)
        cancelAllProcessing()
        store = s
        projectTitle = s.manifest.title
        projectSettings = s.settings
        glossary = s.glossary
        pages = s.loadPages()
        // Pages interrupted mid-stage on a previous run go back to pending (results so far are kept).
        for i in pages.indices where pages[i].status.isWorking { pages[i].status = .pending; try? s.savePage(pages[i]) }
        selectedRegionIDs = []
        selectedPageID = pages.first?.id
        settings.stored.lastProjectPath = url.path
        showLibrary = false
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        undoManager?.removeAllActions()
        pageChanged()
    }

    func newProject(title: String = "Untitled Comic") {
        do {
            let dir = settings.projectLocation
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var url = dir.appendingPathComponent("\(title).\(ProjectStore.fileExtension)")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent("\(title) \(n).\(ProjectStore.fileExtension)"); n += 1
            }
            var s = settings.stored.defaults
            s.defaultStyle = settings.stored.defaults.defaultStyle
            let store = try ProjectStore.create(at: url, title: url.deletingPathExtension().lastPathComponent, settings: s)
            try openProject(store.url)
        } catch { show(error, title: "Could not create project") }
    }

    func openSample() {
        do {
            let dir = settings.projectLocation
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var url = dir.appendingPathComponent("PanelLingo Sample.\(ProjectStore.fileExtension)")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent("PanelLingo Sample \(n).\(ProjectStore.fileExtension)"); n += 1
            }
            let s = try SampleComic.createSampleProject(at: url)
            var ps = s.settings
            ps.translationProvider = settings.stored.defaults.translationProvider
            ps.translationModel = settings.stored.defaults.translationModel
            try s.saveSettings(ps)
            try openProject(s.url)
        } catch { show(error, title: "Could not create the sample project") }
    }

    func presentOpenPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(exportedAs: ProjectStore.typeIdentifier, conformingTo: .package)]
        p.treatsFilePackagesAsDirectories = false
        p.canChooseDirectories = false
        if p.runModal() == .OK, let url = p.url { do { try openProject(url) } catch { show(error, title: "Could not open project") } }
    }

    func presentSaveAs() {
        guard let store else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = projectTitle
        p.allowedContentTypes = [UTType(exportedAs: ProjectStore.typeIdentifier, conformingTo: .package)]
        p.canCreateDirectories = true
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let title = url.deletingPathExtension().lastPathComponent
            let copy = try store.duplicate(to: url, title: title)
            try openProject(copy.url)
            toast = "Saved as \(title)"
        } catch { show(error, title: "Save As failed") }
    }

    // MARK: - Library

    func reloadLibrary() {
        let lib = seriesLibrary
        let recents = NSDocumentController.shared.recentDocumentURLs + [store?.url].compactMap { $0 }
        libraryLoading = true
        Task.detached(priority: .userInitiated) {
            let snap = lib.scan(extra: recents)
            await MainActor.run {
                self.library = snap
                self.libraryLoading = false
                if let sel = self.librarySelection, sel != Self.unsortedID, snap.series(id: sel) == nil { self.librarySelection = nil }
            }
        }
    }

    func showSeries(_ id: String?) {
        librarySelection = id
        showLibrary = true
        reloadLibrary()
    }

    /// Creates one chapter per PDF / archive / folder (loose images together). Chapters go into
    /// `seriesID` when given; otherwise into the series whose name matches the file name, which is
    /// created if needed. Names without a recognisable series stay unsorted.
    func importAsChapters(_ urls: [URL], into seriesID: String? = nil, translate: Bool = false) {
        let groups = ChapterLibrary.groupIntoChapters(urls)
        guard !groups.isEmpty else { return }
        let lib = seriesLibrary
        importProgress = (0, "Creating \(groups.count) chapter\(groups.count == 1 ? "" : "s")…")
        Task {
            var snap = lib.scan()
            var created: [URL] = []
            var problems: [String] = []
            for (i, g) in groups.enumerated() {
                do {
                    let guess = ChapterLibrary.guess(from: g.name)
                    var series: SeriesEntry? = seriesID.flatMap { snap.series(id: $0) }
                    if series == nil, seriesID == nil, let name = guess.series {
                        series = snap.matchSeries(named: name)
                        if series == nil {
                            var info = SeriesInfo(name: name)
                            let d = self.settings.stored.defaults
                            info.sourceLanguage = d.sourceLanguage; info.targetLanguage = d.targetLanguage; info.readingDirection = d.readingDirection
                            let folder = try lib.createSeries(info)
                            series = SeriesEntry(info: info, folder: folder, chapters: [])
                            snap.series.append(series!)
                        }
                    }
                    let url = try lib.newChapterURL(name: g.name, in: series?.folder)
                    let settings = series?.info.chapterSettings(base: self.settings.stored.defaults) ?? self.settings.stored.defaults
                    let title = series != nil && guess.chapter != nil ? "\(series!.info.name) – Chapter \(guess.chapter!)" : g.name
                    let s = try ProjectStore.create(at: url, title: title, settings: settings)
                    try s.updateManifest { $0.series = series?.info.name; $0.chapter = guess.chapter }
                    self.importProgress = (Double(i) / Double(groups.count), g.name)
                    let report = await DefaultComicImportService().importItems(g.items, into: s)
                    if report.added.isEmpty {
                        problems.append("\(g.name): " + (report.failures.first?.reason ?? (report.duplicates.isEmpty ? "no pages" : "duplicate pages only")))
                        try? FileManager.default.removeItem(at: url)
                    } else {
                        created.append(url)
                        if !report.failures.isEmpty { problems.append("\(g.name): \(report.failures.count) file(s) failed") }
                    }
                } catch { problems.append("\(g.name): \(error.localizedDescription)") }
            }
            self.importProgress = nil
            self.library = lib.scan(extra: NSDocumentController.shared.recentDocumentURLs)
            if let last = created.last {
                do { try self.openProject(last) } catch { self.show(error, title: "Could not open chapter") }
                if translate { self.startBatch() }
            }
            let msg = "Added \(created.count) chapter\(created.count == 1 ? "" : "s")"
            if problems.isEmpty { self.toast = msg } else { self.alert = AlertItem(title: msg, message: problems.joined(separator: "\n")) }
        }
    }

    func presentAddChaptersPanel(into seriesID: String? = nil, translate: Bool = false) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = [.image, .pdf, .zip, .folder] + ["cbz", "cbr", "webp"].compactMap { UTType(filenameExtension: $0) }
        let target = seriesID.flatMap { library.series(id: $0)?.info.name }
        p.message = (target.map { "Add to “\($0)”. " } ?? "") + "Each PDF, CBZ/CBR or folder becomes one chapter. Loose images become a single chapter."
        if p.runModal() == .OK { importAsChapters(p.urls, into: seriesID, translate: translate) }
    }

    func openChapter(_ c: ChapterSummary) {
        if store?.url.standardizedFileURL == c.url.standardizedFileURL { showLibrary = false; return }
        do { try openProject(c.url) } catch { show(error, title: "Could not open chapter") }
    }

    private func closeIfOpen(_ url: URL) -> Bool {
        guard store?.url.standardizedFileURL == url.standardizedFileURL || (store?.url.path.hasPrefix(url.standardizedFileURL.path + "/") ?? false) else { return false }
        cancelAllProcessing()
        store = nil; pages = []; selectedPageID = nil; settings.stored.lastProjectPath = nil
        return true
    }

    func trashChapter(_ c: ChapterSummary) {
        _ = closeIfOpen(c.url)
        NSWorkspace.shared.recycle([c.url]) { _, error in
            Task { @MainActor in
                if let error { self.show(error, title: "Could not move to Trash") } else { self.toast = "Moved “\(c.title)” to the Trash" }
                self.reloadLibrary()
            }
        }
    }

    func updateChapterInfo(_ url: URL, title: String, series: String, chapter: String) {
        do {
            let s = (store?.url.standardizedFileURL == url.standardizedFileURL) ? store! : try ProjectStore.open(url)
            try s.updateManifest {
                $0.title = title.isEmpty ? $0.title : title
                $0.chapter = chapter.trimmingCharacters(in: .whitespaces).nilIfEmptyString
            }
            if s === store { projectTitle = s.manifest.title }
            reloadLibrary()
        } catch { show(error, title: "Could not update chapter") }
    }

    // MARK: - Series

    /// Creates or updates a series and applies relation changes to both sides.
    func saveSeries(_ info: SeriesInfo, existing: SeriesEntry?, relations: [SeriesRelation]) {
        let lib = seriesLibrary
        do {
            var entry: SeriesEntry
            if let existing {
                var updated = info
                updated.related = existing.info.related
                let folder = try lib.updateSeries(updated, folder: existing.folder)
                entry = SeriesEntry(info: updated, folder: folder, chapters: existing.chapters)
            } else {
                var fresh = info
                fresh.related = []
                entry = SeriesEntry(info: fresh, folder: try lib.createSeries(fresh), chapters: [])
            }
            var snap = lib.scan()
            let wanted = Dictionary(uniqueKeysWithValues: relations.map { ($0.seriesID, $0) })
            for old in entry.info.related where wanted[old.seriesID] == nil {
                if let other = snap.series(id: old.seriesID), let me = snap.series(id: entry.id) { try lib.unlink(me, other) }
            }
            snap = lib.scan()
            for r in relations {
                guard let me = snap.series(id: entry.id), let other = snap.series(id: r.seriesID) else { continue }
                if me.info.related.contains(r) { continue }
                try lib.link(me, other, kind: r.kind, shareGlossary: r.shareGlossary)
                snap = lib.scan()
            }
            library = lib.scan(extra: NSDocumentController.shared.recentDocumentURLs)
            if existing == nil { librarySelection = entry.id }
            // Reopen the current chapter if its series folder was renamed.
            if let url = store?.url, !FileManager.default.fileExists(atPath: url.path), let open = existing,
               let moved = library.series(id: open.id)?.chapters.first(where: { $0.url.lastPathComponent == url.lastPathComponent }) {
                try? openProject(moved.url); showLibrary = true
            }
        } catch { show(error, title: "Could not save series") }
    }

    /// Removes a series. With `keepChapters` its chapters become unsorted; otherwise the folder
    /// and its chapters go to the Trash (recoverable).
    func deleteSeries(_ entry: SeriesEntry, keepChapters: Bool) {
        let lib = seriesLibrary
        _ = closeIfOpen(entry.folder)
        do {
            if keepChapters { _ = try lib.dissolveSeries(folder: entry.folder, snapshot: library) }
            else { try lib.removeRelations(ofSeriesIn: entry.folder, snapshot: library) }
        } catch { show(error, title: "Could not remove series"); return }
        NSWorkspace.shared.recycle([entry.folder]) { _, error in
            Task { @MainActor in
                if let error { self.show(error, title: "Could not move to Trash") }
                else { self.toast = keepChapters ? "Removed series “\(entry.info.name)”; its chapters are now unsorted" : "Moved “\(entry.info.name)” and its chapters to the Trash" }
                self.librarySelection = nil
                self.reloadLibrary()
            }
        }
    }

    func moveChapter(_ c: ChapterSummary, toSeries id: String?) {
        let lib = seriesLibrary
        let target = id.flatMap { library.series(id: $0) }
        let wasOpen = store?.url.standardizedFileURL == c.url.standardizedFileURL
        do {
            if wasOpen { cancelAllProcessing(); store = nil }
            let newURL = try lib.moveChapter(c.url, toSeriesFolder: target?.folder, seriesName: target?.info.name)
            // Chapter adopts the new series' translation defaults.
            if let t = target, let s = try? ProjectStore.open(newURL) { try? s.saveSettings(t.info.chapterSettings(base: s.settings)) }
            if wasOpen { try openProject(newURL); showLibrary = true }
            toast = "Moved to " + (target?.info.name ?? "Unsorted")
        } catch { show(error, title: "Could not move chapter") }
        reloadLibrary()
    }

    /// Files every unsorted chapter whose name reveals a series into that series (creating it if needed).
    func organizeUnsorted() {
        let lib = seriesLibrary
        var snap = lib.scan()
        var moved = 0
        let rootPath = lib.root.resolvingSymlinksInPath().path
        // Only chapters stored in the library folder itself (not recent projects elsewhere).
        for c in snap.unsorted where c.url.deletingLastPathComponent().resolvingSymlinksInPath().path == rootPath {
            let name = c.series ?? ChapterLibrary.guess(from: c.url.deletingPathExtension().lastPathComponent).series
            guard let name else { continue }
            do {
                var entry = snap.matchSeries(named: name)
                if entry == nil {
                    let info = SeriesInfo(name: name)
                    entry = SeriesEntry(info: info, folder: try lib.createSeries(info), chapters: [])
                    snap.series.append(entry!)
                }
                if store?.url.standardizedFileURL == c.url.standardizedFileURL { cancelAllProcessing(); store = nil; pages = [] }
                try lib.moveChapter(c.url, toSeriesFolder: entry!.folder, seriesName: entry!.info.name)
                moved += 1
            } catch { problemsToast(error) }
        }
        toast = moved == 0 ? "No chapter names matched a series" : "Filed \(moved) chapter\(moved == 1 ? "" : "s") into series"
        reloadLibrary()
    }

    private func problemsToast(_ e: Error) { toast = e.localizedDescription }

    func saveSeriesGlossary(_ g: [GlossaryEntry]) {
        guard var entry = currentSeries else { return }
        entry.info.glossary = g
        do { try seriesLibrary.saveInfo(entry.info, folder: entry.folder); reloadLibrary() } catch { show(error, title: "Could not save series glossary") }
    }

    func renameProject(_ title: String) {
        guard let store, !title.isEmpty else { return }
        try? store.updateManifest { $0.title = title }
        projectTitle = title
    }

    func updateProjectSettings(_ body: (inout ProjectSettings) -> Void) {
        var s = projectSettings
        body(&s)
        guard s != projectSettings else { return }
        let directionChanged = s.readingDirection != projectSettings.readingDirection
        projectSettings = s
        try? store?.saveSettings(s)
        if directionChanged, let id = selectedPageID { reorderAutomatically(id) }
    }

    func saveGlossary(_ g: [GlossaryEntry]) {
        glossary = g
        do { try store?.saveGlossary(g) } catch { show(error, title: "Could not save glossary") }
    }

    // MARK: - Import

    func presentImportPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = [.image, .pdf, .zip, .folder] + ["cbz", "cbr", "webp"].compactMap { UTType(filenameExtension: $0) }
        p.message = "Choose comic images, PDFs, CBZ/CBR archives or folders"
        if p.runModal() == .OK { importItems(p.urls) }
    }

    func importItems(_ urls: [URL], at index: Int? = nil) {
        // Outside a project (or from the library) every PDF / archive / folder becomes its own chapter.
        if store == nil || showLibrary { importAsChapters(urls); return }
        guard let store else { return }
        importProgress = (0, "Importing…")
        Task {
            let report = await DefaultComicImportService().importItems(urls, into: store, at: index) { p, name in
                Task { @MainActor in self.importProgress = (p, name) }
            }
            self.importProgress = nil
            self.pages = store.loadPages()
            if self.selectedPageID == nil || !report.added.isEmpty { self.selectedPageID = report.added.first?.id ?? self.selectedPageID }
            var msg = report.summary
            if !report.failures.isEmpty { msg += "\n" + report.failures.prefix(5).map { "• \($0.name): \($0.reason)" }.joined(separator: "\n") }
            if report.failures.isEmpty { self.toast = msg } else { self.alert = AlertItem(title: "Import finished with problems", message: msg) }
        }
    }

    func pasteFromClipboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            importItems(urls); return
        }
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) else { toast = "The clipboard has no image"; return }
        if store == nil { newProject() }
        guard let store else { return }
        do {
            let png = (pb.data(forType: .png) != nil) ? data : (NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data)
            let page = try DefaultComicImportService().importData(png, name: "Pasted \(pages.count + 1)", into: store)
            pages = store.loadPages()
            selectedPageID = page.id
        } catch { show(error, title: "Paste failed") }
    }

    // MARK: - Pages

    func movePages(from: IndexSet, to: Int) {
        pages.move(fromOffsets: from, toOffset: to)
        try? store?.reorderPages(pages.map(\.id))
    }

    func renamePage(_ id: String, to name: String) {
        mutatePage(id, "Rename Page") { $0.name = name }
    }

    func deletePages(_ ids: Set<String>) {
        guard let store else { return }
        for id in ids { pageTasks[id]?.cancel(); try? store.removePage(id) }
        pages = store.loadPages()
        if let s = selectedPageID, ids.contains(s) { selectedPageID = pages.first?.id }
        undoManager?.removeAllActions()
    }

    private func pageChanged() {
        selectedRegionIDs = []
        editingRegionID = nil
        readingOrderSequence = []
        originalImage = nil; cleanedImage = nil; translatedImage = nil
        guard let page = currentPage, let store else { return }
        originalImage = try? store.originalImage(page)
        scheduleRender(immediate: true)
        canvas.send(.fitPage)
    }

    // MARK: - Rendering

    func scheduleRender(immediate: Bool = false) {
        renderTask?.cancel()
        guard let page = currentPage, let store, let original = originalImage else { return }
        renderGeneration += 1
        let gen = renderGeneration
        let target = projectSettings.targetLanguage
        let editing = editingRegionID
        renderTask = Task.detached(priority: .userInitiated) {
            if !immediate { try? await Task.sleep(nanoseconds: 60_000_000) }
            if Task.isCancelled { return }
            let renderer = PageRenderer()
            let cleaned = try? renderer.render(page: page, original: original, layers: store, mode: .cleaned, targetLanguage: target)
            if Task.isCancelled { return }
            // While editing in place, the edited bubble's lettering is shown by the live editor instead.
            let translated = try? renderer.render(page: page, original: original, layers: store, mode: .translated,
                                                  targetLanguage: target, excluding: editing.map { [$0] } ?? [])
            await MainActor.run {
                guard gen == self.renderGeneration else { return }
                self.cleanedImage = cleaned
                self.translatedImage = translated
            }
        }
    }

    func image(for mode: RenderMode) -> CGImage? {
        switch mode {
        case .original: originalImage
        case .cleaned: cleanedImage ?? originalImage
        case .translated: translatedImage ?? cleanedImage ?? originalImage
        }
    }

    // MARK: - Undoable editing

    /// Applies an undoable change to a page and persists it.
    func mutatePage(_ id: String, _ actionName: String, _ body: (inout ComicPage) -> Void) {
        guard let i = pageIndex(id) else { return }
        let old = pages[i]
        var new = old
        body(&new)
        guard new != old else { return }
        replacePage(new, previous: old, actionName: actionName)
    }

    private func replacePage(_ new: ComicPage, previous: ComicPage, actionName: String) {
        guard let i = pageIndex(new.id) else { return }
        var page = new
        refreshLayoutState(&page, previous: previous)
        pages[i] = page
        do { try store?.savePage(page) } catch { show(error, title: "Could not save") }
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.replacePage(previous, previous: page, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
        selectedRegionIDs = selectedRegionIDs.filter { id in page.regions.contains { $0.id == id } }
        if page.id == selectedPageID { scheduleRender() }
    }

    /// Re-fits lettering for regions whose text, style or geometry changed (no OCR / cleanup re-run).
    private func refreshLayoutState(_ page: inout ComicPage, previous: ComicPage) {
        let engine = CoreTextLayoutEngine()
        for i in page.regions.indices {
            let r = page.regions[i]
            let old = previous.regions.first { $0.id == r.id }
            guard old == nil || old!.translation != r.translation || old!.style != r.style || old!.bbox != r.bbox
                    || old!.textArea != r.textArea || old!.polygon != r.polygon else { continue }
            page.regions[i].reviewReasons.removeAll { $0.hasPrefix("Text overflow") }
            guard let t = r.translatedText, !t.isEmpty else { page.regions[i].layout = LayoutState(); page.regions[i].normalizeReview(); continue }
            let res = engine.layout(text: t, style: r.style, area: TextArea.forRegion(r), language: projectSettings.targetLanguage)
            page.regions[i].layout.fittedFontSize = res.fontSize
            page.regions[i].layout.overflow = res.overflow
            page.regions[i].layout.lineCount = res.lines.count
            if res.overflow { page.regions[i].flagReview("Text overflow: shorten the translation or enlarge the text area") }
            page.regions[i].normalizeReview()
        }
    }

    func updateRegion(_ regionID: String, _ actionName: String, _ body: (inout TextRegion) -> Void) {
        guard let pid = selectedPageID else { return }
        mutatePage(pid, actionName) { page in
            if let i = page.regionIndex(regionID) { body(&page.regions[i]) }
        }
    }

    func updateSelectedRegions(_ actionName: String, _ body: (inout TextRegion) -> Void) {
        guard let pid = selectedPageID else { return }
        let ids = selectedRegionIDs
        mutatePage(pid, actionName) { page in
            for i in page.regions.indices where ids.contains(page.regions[i].id) { body(&page.regions[i]) }
        }
    }

    // MARK: - Region commands

    func addRegion(bbox: PixelRect, polygon: [PixelPoint]? = nil) {
        guard let pid = selectedPageID, bbox.width >= 4, bbox.height >= 4 else { return }
        var r = TextRegion(kind: .speech, bbox: bbox, polygon: polygon, confidence: 1, detector: "manual",
                           style: projectSettings.defaultStyle)
        r.isManual = true
        let id = r.id
        mutatePage(pid, "Add Region") { page in
            r.readingIndex = (page.regions.map(\.readingIndex).max() ?? -1) + 1
            page.regions.append(r)
            ReadingOrder.assignPanels(&page.regions, panels: page.panels)
        }
        selectedRegionIDs = [id]
        tool = .select
    }

    func deleteSelectedRegions() {
        guard let pid = selectedPageID, !selectedRegionIDs.isEmpty else { return }
        let ids = selectedRegionIDs
        mutatePage(pid, "Delete Region") { page in
            page.regions.removeAll { ids.contains($0.id) }
            page.renumberReadingOrder()
        }
        selectedRegionIDs = []
    }

    func mergeSelectedRegions() {
        guard let page = currentPage, selectedRegionIDs.count >= 2 else { return }
        let regions = page.regions.filter { selectedRegionIDs.contains($0.id) }
        guard let merged = RegionAssembler.merge(regions) else { return }
        let ids = selectedRegionIDs
        mutatePage(page.id, "Merge Regions") { p in
            p.regions.removeAll { ids.contains($0.id) && $0.id != merged.id }
            if let i = p.regionIndex(merged.id) { p.regions[i] = merged }
            p.renumberReadingOrder()
        }
        selectedRegionIDs = [merged.id]
    }

    func splitSelectedRegion() {
        guard let r = selectedRegion, let pid = selectedPageID else { return }
        let parts = RegionAssembler.split(r)
        mutatePage(pid, "Split Region") { p in
            for i in p.regions.indices where p.regions[i].readingIndex > r.readingIndex { p.regions[i].readingIndex += 1 }
            p.regions.removeAll { $0.id == r.id }
            p.regions += parts
            p.renumberReadingOrder()
        }
        selectedRegionIDs = Set(parts.map(\.id))
    }

    func moveRegionsInOrder(from: IndexSet, to: Int) {
        guard let page = currentPage else { return }
        var ids = page.orderedRegions.map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        mutatePage(page.id, "Change Reading Order") { ReadingOrder.apply(order: ids, to: &$0) }
    }

    /// Reading Order mode: clicking regions in sequence assigns 1, 2, 3…
    func readingOrderClick(_ id: String) {
        guard let page = currentPage else { return }
        if readingOrderSequence.contains(id) { readingOrderSequence.removeAll { $0 == id } } else { readingOrderSequence.append(id) }
        let seq = readingOrderSequence
        mutatePage(page.id, "Change Reading Order") { ReadingOrder.apply(order: seq, to: &$0) }
        if readingOrderSequence.count == page.regions.count { toast = "Reading order set"; tool = .select }
    }

    func reorderAutomatically(_ pageID: String) {
        mutatePage(pageID, "Auto Reading Order") { p in
            p.regions = ReadingOrder.order(p.regions, panels: p.panels, direction: projectSettings.readingDirection)
        }
    }

    func restoreOriginal(_ ids: Set<String>) {
        guard let page = currentPage, let store else { return }
        // Capture layer files so restore is undoable.
        let snapshots = ids.map { ($0, store.maskData(pageID: page.id, regionID: $0), store.patchData(pageID: page.id, regionID: $0)) }
        mutatePage(page.id, "Restore Original") { p in
            for i in p.regions.indices where ids.contains(p.regions[i].id) {
                p.regions[i].cleanup.status = .restored
                p.regions[i].cleanup.manualMask = false
            }
        }
        for id in ids { store.removePatch(pageID: page.id, regionID: id) }
        undoManager?.registerUndo(withTarget: self) { t in
            MainActor.assumeIsolated {
                for (id, m, p) in snapshots { t.store?.restoreLayers(pageID: page.id, regionID: id, mask: m, patch: p) }
                t.scheduleRender()
            }
        }
        scheduleRender()
    }

    // MARK: - Mask editing

    func paintMask(regionID: String, points: [PixelPoint], erase: Bool) {
        guard let page = currentPage, let store, let original = originalImage,
              let region = page.regions.first(where: { $0.id == regionID }) else { return }
        let beforeMask = store.maskData(pageID: page.id, regionID: regionID)
        let beforePatch = store.patchData(pageID: page.id, regionID: regionID)
        var rect = region.cleanup.maskRect ?? region.bbox.insetBy(dx: -8, dy: -8).integral.clamped(width: Double(original.width), height: Double(original.height))
        var mask = store.loadMask(pageID: page.id, regionID: regionID) ?? BitMask(width: Int(rect.width), height: Int(rect.height))
        // Grow the mask canvas if the stroke leaves it.
        let strokeBox = PolygonMath.boundingRect(points).insetBy(dx: -brushSize, dy: -brushSize).integral
        if !rect.contains(strokeBox) {
            let grown = rect.union(strokeBox).clamped(width: Double(original.width), height: Double(original.height)).integral
            var m2 = BitMask(width: Int(grown.width), height: Int(grown.height))
            for y in 0..<mask.height { for x in 0..<mask.width where mask[x, y] {
                let gx = x + Int(rect.x - grown.x), gy = y + Int(rect.y - grown.y)
                if gx >= 0, gy >= 0, gx < m2.width, gy < m2.height { m2[gx, gy] = true }
            } }
            mask = m2; rect = grown
        }
        CleanupService.paint(&mask, maskRect: rect, points: points, radius: brushSize / 2, add: !erase)
        do {
            try store.saveMask(mask, pageID: page.id, regionID: regionID)
            var r = region
            r.cleanup.maskRect = rect
            r.cleanup.manualMask = true
            let out = try CleanupService().clean(image: original, region: r, mode: projectSettings.cleanupMode, manualMask: (rect, mask))
            if let p = out.patch?.cgImage() { try store.savePatch(p, pageID: page.id, regionID: regionID) } else { store.removePatch(pageID: page.id, regionID: regionID) }
            updateRegion(regionID, erase ? "Erase Mask" : "Paint Mask") { reg in
                reg.cleanup.maskRect = rect
                reg.cleanup.manualMask = true
                reg.cleanup.maskRevision += 1
                reg.cleanup.status = out.patch == nil ? .skipped : .cleaned
                reg.cleanup.mode = out.mode
                reg.reviewReasons.removeAll { $0.hasPrefix("Cleanup") }
                reg.normalizeReview()
            }
            undoManager?.registerUndo(withTarget: self) { t in
                MainActor.assumeIsolated { t.store?.restoreLayers(pageID: page.id, regionID: regionID, mask: beforeMask, patch: beforePatch); t.scheduleRender() }
            }
        } catch { show(error, title: "Mask edit failed") }
    }

    func resetMask(_ regionID: String) {
        updateRegion(regionID, "Reset Mask") { $0.cleanup.manualMask = false; $0.cleanup.status = .none }
        runPipeline(.only(.clean, regions: [regionID]))
    }

    // MARK: - Pipeline

    /// Asks before content is first sent to a cloud provider in this session.
    func withCloudConsent(_ request: PipelineRequest, pages ids: [String], _ proceed: @escaping () -> Void) {
        let cfg = settings.provider(projectSettings.translationProvider)
        let sendsText = request.stages.contains(.translate) || (request.stages.contains(.ocr) && projectSettings.ocrEngine == .aiVision)
        guard sendsText, !cfg.isLocal, !sessionConsent.contains(cfg.kind) else { proceed(); return }
        let chars = ids.compactMap { pageIndex($0).map { pages[$0] } }.flatMap(\.regions).reduce(0) { $0 + $1.sourceText.count }
        let images = (settings.stored.includePageImage && settings.stored.privacy.allowSendingImages) || projectSettings.ocrEngine == .aiVision
        consent = ConsentRequest(provider: cfg.kind, characters: chars, includesImages: images) { [weak self] in
            self?.sessionConsent.insert(cfg.kind)
            proceed()
        }
    }

    func runPipeline(_ request: PipelineRequest, pageID: String? = nil) {
        guard let store, let pid = pageID ?? selectedPageID, pageTasks[pid] == nil else { return }
        withCloudConsent(request, pages: [pid]) { [self] in
            guard let page = pages.first(where: { $0.id == pid }) else { return }
            let engine = PipelineEngine(store: store)
            let options = pipelineOptions
            pageTasks[pid] = Task {
                defer { self.pageTasks[pid] = nil }
                do {
                    let result = try await engine.run(page, request: request, options: options) { p in
                        Task { @MainActor in self.applyPipelineUpdate(p) }
                    }
                    self.applyPipelineUpdate(result)
                    self.undoManager?.removeAllActions(withTarget: self)
                } catch PanelLingoError.cancelled {
                    self.toast = "Cancelled"
                } catch {
                    if let p = store.loadPage(pid) { self.applyPipelineUpdate(p) }
                    self.show(error, title: "Processing stopped")
                }
            }
        }
    }

    private func applyPipelineUpdate(_ p: ComicPage) {
        guard let i = pageIndex(p.id) else { return }
        pages[i] = p
        selectedRegionIDs = selectedRegionIDs.filter { id in p.regions.contains { $0.id == id } }
        if p.id == selectedPageID { scheduleRender() }
    }

    func cancelProcessing(_ pageID: String) { pageTasks[pageID]?.cancel() }

    func cancelAllProcessing() {
        for t in pageTasks.values { t.cancel() }
        pageTasks = [:]
        Task { await batch?.cancel() }
    }

    func translateCurrentPage() { runPipeline(.full) }
    func detectCurrentPage() { runPipeline(PipelineRequest(stages: [.detect], force: true)) }

    func retranslate(_ ids: Set<String>) {
        guard let pid = selectedPageID else { return }
        mutatePage(pid, "Unlock Translation") { p in
            for i in p.regions.indices where ids.contains(p.regions[i].id) { p.regions[i].translationLocked = false }
        }
        runPipeline(PipelineRequest(stages: [.translate, .typeset], regionIDs: ids, force: true))
    }

    func rerunOCR(_ ids: Set<String>) { runPipeline(PipelineRequest(stages: [.ocr], regionIDs: ids, force: true)) }
    func clean(_ ids: Set<String>) { runPipeline(PipelineRequest(stages: [.clean, .typeset], regionIDs: ids, force: true)) }

    /// Translates one region with a second provider for side-by-side comparison (not applied).
    func compare(regionID: String, with kind: ProviderKind) {
        guard let page = currentPage, let r = page.regions.first(where: { $0.id == regionID }) else { return }
        var req = TranslationRequest(sourceLanguage: projectSettings.sourceLanguage, targetLanguage: projectSettings.targetLanguage,
                                     items: [TranslationItem(id: r.id, text: r.sourceText, kind: r.kind.rawValue)])
        req.nearbyContext = page.orderedRegions.filter { $0.id != r.id }.map { ContextLine(source: $0.sourceText, translation: $0.translatedText) }
        req.glossary = glossary; req.tone = projectSettings.tone; req.honorifics = projectSettings.honorifics
        req.customInstructions = projectSettings.customInstructions; req.storyContext = projectSettings.storyContext
        let engine = TranslationEngine(configurations: settings.providerMap, privacy: settings.stored.privacy)
        let cfg = settings.provider(kind)
        let run = { [self] in
            Task {
                do {
                    let res = try await engine.translate(req, config: cfg)
                    if let o = res.outputs.first {
                        let rec = TranslationRecord(text: o.translatedText, provider: kind.rawValue, model: res.model, modelConfidence: o.confidence,
                                                    reviewRequired: o.reviewRequired, notes: o.notes, sourceText: r.sourceText)
                        self.alternatives[regionID, default: []].insert(rec, at: 0)
                    }
                } catch { self.show(error, title: "Comparison failed") }
            }
        }
        if cfg.isLocal || sessionConsent.contains(kind) { _ = run() } else {
            consent = ConsentRequest(provider: kind, characters: r.sourceText.count, includesImages: false) { [weak self] in
                self?.sessionConsent.insert(kind); _ = run()
            }
        }
    }

    func useAlternative(_ rec: TranslationRecord, for regionID: String) {
        updateRegion(regionID, "Use Alternative Translation") { r in
            r.translation = rec
            r.translationLocked = true
        }
    }

    // MARK: - Batch

    func startBatch(pageIDs: [String]? = nil, force: Bool = false) {
        guard let store else { return }
        let ids = pageIDs ?? pages.map(\.id)
        withCloudConsent(.full, pages: ids) { [self] in
            let cfg = settings.provider(projectSettings.translationProvider)
            let local = cfg.isLocal && cfg.kind != .apple
            let conc = local ? settings.stored.processing.concurrentLocalInference : settings.stored.processing.concurrentPages
            let queue = BatchQueue(engine: PipelineEngine(store: store), options: pipelineOptions,
                                   request: PipelineRequest(force: force), concurrency: conc,
                                   onPage: { p in Task { @MainActor in self.applyPipelineUpdate(p) } },
                                   onSnapshot: { s in Task { @MainActor in self.batchSnapshot = s } })
            batch = queue
            showBatch = true
            Task { await queue.start(pageIDs: ids) }
        }
    }

    // MARK: - Helpers

    func show(_ error: Error, title: String) {
        alert = AlertItem(title: title, message: error.localizedDescription)
    }

    func searchResults() -> [(page: ComicPage, region: TextRegion)] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return pages.flatMap { p in
            p.orderedRegions.filter { $0.sourceText.localizedCaseInsensitiveContains(q) || ($0.translatedText ?? "").localizedCaseInsensitiveContains(q) }
                .map { (p, $0) }
        }
    }

    func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func reveal(_ pageID: String, region: String) {
        selectedPageID = pageID
        selectedRegionIDs = [region]
    }
}

extension String {
    var nilIfEmptyString: String? { isEmpty ? nil : self }
}
