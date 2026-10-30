import PanelLingoKit
import SwiftUI

/// Library → Series → Chapters. The top level lists series (plus unsorted chapters); selecting a
/// series shows its details, related series and chapters.
struct LibraryView: View {
    @Bindable var app: AppState
    @State private var search = ""
    @State private var filter: ChapterFilter = .all
    @State private var editingSeries: SeriesEditorTarget?
    @State private var editingChapter: ChapterSummary?
    @State private var confirmTrash: ChapterSummary?
    @State private var confirmDeleteSeries: SeriesEntry?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if app.library.series.isEmpty && app.library.unsorted.isEmpty && !app.libraryLoading {
                    emptyState
                } else if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchResults
                } else if let sel = app.librarySelection {
                    if sel == AppState.unsortedID { unsortedDetail } else if let s = app.library.series(id: sel) { seriesDetail(s) } else { seriesGrid }
                } else {
                    seriesGrid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .task { app.reloadLibrary() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { urls in
                if let sel = app.librarySelection, sel != AppState.unsortedID { app.importAsChapters(urls, into: sel) }
                else { app.importAsChapters(urls) }
            }
            return true
        }
        .sheet(item: $editingSeries) { t in SeriesEditor(app: app, target: t) }
        .sheet(item: $editingChapter) { c in ChapterInfoSheet(app: app, chapter: c) }
        .confirmationDialog("Move “\(confirmTrash?.title ?? "")” to the Trash?", isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } })) {
            Button("Move to Trash", role: .destructive) { if let c = confirmTrash { app.trashChapter(c) }; confirmTrash = nil }
        } message: { Text("The chapter's original pages and translations go to the Trash. You can restore them from there.") }
        .confirmationDialog("Remove series “\(confirmDeleteSeries?.info.name ?? "")”?", isPresented: Binding(get: { confirmDeleteSeries != nil }, set: { if !$0 { confirmDeleteSeries = nil } })) {
            Button("Remove Series, Keep Chapters") { if let s = confirmDeleteSeries { app.deleteSeries(s, keepChapters: true) }; confirmDeleteSeries = nil }
            Button("Move Series and Chapters to Trash", role: .destructive) { if let s = confirmDeleteSeries { app.deleteSeries(s, keepChapters: false) }; confirmDeleteSeries = nil }
        } message: { Text("Kept chapters move to Unsorted. Anything moved to the Trash can be restored from there.") }
    }

    // MARK: Header

    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if app.librarySelection != nil {
                    Button { app.librarySelection = nil } label: { Label("All Series", systemImage: "chevron.left") }
                        .buttonStyle(.borderless).help("Back to all series")
                }
                Text(title).font(.title2.bold()).lineLimit(1).layoutPriority(1)
                Text(summaryLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button { app.reloadLibrary() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh").buttonStyle(.borderless)
                Button { editingSeries = .new } label: { Label("New Series", systemImage: "folder.badge.plus") }.fixedSize()
                Menu {
                    Button("Add Chapters…") { addChapters() }
                    Button("Add Chapters and Translate…") { addChapters(translate: true) }
                    Divider()
                    Button("Open Project…") { app.presentOpenPanel() }
                    Button("Open Sample Project") { app.openSample() }
                    Divider()
                    Button("Show Library Folder in Finder") { app.revealInFinder(app.settings.projectLocation) }
                } label: { Label("Add Chapters", systemImage: "plus") } primaryAction: { addChapters() }
                .fixedSize()
            }
            HStack(spacing: 12) {
                TextField("Search series or chapters", text: $search).textFieldStyle(.roundedBorder).frame(minWidth: 140, maxWidth: 260)
                if app.librarySelection != nil {
                    Picker("Show", selection: $filter) { ForEach(ChapterFilter.allCases) { Text($0.rawValue).tag($0) } }.fixedSize()
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    var title: String {
        switch app.librarySelection {
        case nil: "Library"
        case AppState.unsortedID: "Unsorted Chapters"
        case let id?: app.library.series(id: id)?.info.name ?? "Library"
        }
    }

    var summaryLine: String {
        let lib = app.library
        if let id = app.librarySelection, let s = lib.series(id: id) {
            return "\(s.chapters.count) chapter\(s.chapters.count == 1 ? "" : "s") · \(s.translatedCount) translated"
        }
        let all = lib.allChapters
        let done = all.filter { $0.status == .translated || $0.status == .needsReview }.count
        return "\(lib.series.count) series · \(all.count) chapters · \(done) translated"
    }

    func addChapters(translate: Bool = false) {
        let sel = app.librarySelection
        app.presentAddChaptersPanel(into: sel == AppState.unsortedID ? nil : sel, translate: translate)
    }

    // MARK: Series grid

    var seriesGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 20)], alignment: .leading, spacing: 22) {
                ForEach(app.library.series) { s in
                    SeriesCard(series: s, relatedNames: relatedNames(s), isCurrent: app.currentSeries?.id == s.id)
                        .onTapGesture { app.librarySelection = s.id }
                        .contextMenu { seriesMenu(s) }
                }
                if !app.library.unsorted.isEmpty {
                    UnsortedCard(chapters: app.library.unsorted).onTapGesture { app.librarySelection = AppState.unsortedID }
                }
                NewSeriesCard().onTapGesture { editingSeries = .new }
            }
            .padding(24)
        }
    }

    func relatedNames(_ s: SeriesEntry) -> [String] {
        s.info.related.compactMap { r in app.library.series(id: r.seriesID).map { "\(r.kind.displayName): \($0.info.name)" } }
    }

    @ViewBuilder func seriesMenu(_ s: SeriesEntry) -> some View {
        Button("Open") { app.librarySelection = s.id }
        Button("Add Chapters…") { app.presentAddChaptersPanel(into: s.id) }
        Button("Edit Series…") { editingSeries = .edit(s) }
        Button("Show in Finder") { app.revealInFinder(s.folder) }
        Divider()
        Button("Remove Series…", role: .destructive) { confirmDeleteSeries = s }
    }

    // MARK: Series detail

    func seriesDetail(_ s: SeriesEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    Thumbnail(url: s.coverURL, version: Int(s.modified.timeIntervalSince1970))
                        .frame(width: 120, height: 170).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 8) {
                        if !s.info.alternateNames.isEmpty {
                            Text(s.info.alternateNames.joined(separator: " · ")).foregroundStyle(.secondary)
                        }
                        if !s.info.summary.isEmpty { Text(s.info.summary).lineLimit(4) }
                        Text(defaultsLine(s.info)).font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Image(systemName: "character.book.closed").foregroundStyle(.secondary)
                            Text("\(s.info.glossary.count) series glossary terms").font(.callout).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Add Chapters…") { app.presentAddChaptersPanel(into: s.id) }
                            Button("Edit Series…") { editingSeries = .edit(s) }
                            Button { app.revealInFinder(s.folder) } label: { Image(systemName: "folder") }.help("Show in Finder")
                        }.padding(.top, 4)
                    }
                    Spacer()
                }
                RelatedSeriesRow(app: app, series: s) { editingSeries = .edit(s) }
                let chapters = s.chapters.filter(filter.matches)
                if chapters.isEmpty {
                    Text(s.chapters.isEmpty ? "No chapters yet. Drop PDFs, CBZs or folders here to add them to \(s.info.name)." : "No chapters match this filter.")
                        .foregroundStyle(.secondary).padding(.vertical, 30).frame(maxWidth: .infinity)
                } else {
                    chapterGrid(chapters)
                }
            }
            .padding(24)
        }
    }

    func defaultsLine(_ i: SeriesInfo) -> String {
        let src = i.sourceLanguage.map(LanguageInfo.name) ?? "default source"
        let tgt = i.targetLanguage.map(LanguageInfo.name) ?? "default target"
        let dir = i.readingDirection?.displayName ?? "default reading direction"
        return "\(src) → \(tgt) · \(dir)"
    }

    var unsortedDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Chapters that aren't in a series. Right-click a chapter to move it, or file them automatically by name.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Organize into Series") { app.organizeUnsorted() }
                }
                chapterGrid(app.library.unsorted.filter(filter.matches))
            }
            .padding(24)
        }
    }

    var searchResults: some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        let series = app.library.series.filter { $0.info.matches(q) || $0.info.name.localizedCaseInsensitiveContains(q) || $0.info.alternateNames.contains { $0.localizedCaseInsensitiveContains(q) } }
        let chapters = app.library.allChapters.filter { $0.title.localizedCaseInsensitiveContains(q) || ($0.series ?? "").localizedCaseInsensitiveContains(q) || $0.chapter == q }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !series.isEmpty {
                    Text("Series").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 20)], alignment: .leading, spacing: 20) {
                        ForEach(series) { s in
                            SeriesCard(series: s, relatedNames: relatedNames(s), isCurrent: false)
                                .onTapGesture { search = ""; app.librarySelection = s.id }
                        }
                    }
                }
                Text("Chapters").font(.headline)
                if chapters.isEmpty { Text("No chapters match “\(q)”.").foregroundStyle(.secondary) } else { chapterGrid(chapters) }
            }
            .padding(24)
        }
    }

    func chapterGrid(_ chapters: [ChapterSummary]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 210), spacing: 18)], alignment: .leading, spacing: 20) {
            ForEach(chapters) { c in
                ChapterCard(chapter: c, isOpen: app.store?.url.standardizedFileURL == c.url.standardizedFileURL)
                    .onTapGesture { app.openChapter(c) }
                    .contextMenu { chapterMenu(c) }
            }
        }
    }

    @ViewBuilder func chapterMenu(_ c: ChapterSummary) -> some View {
        Button("Open") { app.openChapter(c) }
        Button("Translate All Pages") { app.openChapter(c); app.startBatch() }.disabled(c.pageCount == 0)
        Button("Export…") { app.openChapter(c); app.showExport = true }.disabled(c.pageCount == 0)
        Divider()
        Menu("Move to Series") {
            ForEach(app.library.series) { s in
                Button(s.info.name) { app.moveChapter(c, toSeries: s.id) }.disabled(app.library.series(containing: c.url)?.id == s.id)
            }
            Divider()
            Button("Unsorted") { app.moveChapter(c, toSeries: nil) }.disabled(app.library.series(containing: c.url) == nil)
        }
        Button("Edit Title & Chapter Number…") { editingChapter = c }
        Button("Show in Finder") { app.revealInFinder(c.url) }
        Divider()
        Button("Move to Trash…", role: .destructive) { confirmTrash = c }
    }

    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical").font(.system(size: 54)).foregroundStyle(.tertiary)
            Text("No series yet").font(.title2.weight(.semibold))
            Text("Create a series, or drop chapter PDFs, CBZ/CBR archives or folders here. Chapters are filed into a series by their file name.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack {
                Button("New Series…") { editingSeries = .new }.controlSize(.large)
                Button("Add Chapters…") { addChapters() }.controlSize(.large)
                Button("Open Sample") { app.openSample() }.controlSize(.large)
            }
            Text("Library folder: \(app.settings.projectLocation.path)").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

enum ChapterFilter: String, CaseIterable, Identifiable {
    case all = "All", translated = "Translated", inProgress = "In Progress", review = "Needs Review", untranslated = "Not Started"
    var id: String { rawValue }
    func matches(_ c: ChapterSummary) -> Bool {
        switch self {
        case .all: true
        case .translated: c.status == .translated || c.status == .needsReview
        case .inProgress: c.status == .inProgress || c.status == .failed
        case .review: c.status == .needsReview || c.status == .failed
        case .untranslated: c.status == .notStarted || c.status == .empty
        }
    }
}

enum SeriesEditorTarget: Identifiable {
    case new
    case edit(SeriesEntry)
    var id: String { if case .edit(let s) = self { return s.id }; return "new" }
}

func loadURLs(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
    var urls: [URL] = []
    let group = DispatchGroup()
    let lock = NSLock()
    for p in providers where p.hasItemConformingToTypeIdentifier("public.file-url") {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { if !urls.isEmpty { done(urls) } } }
}

// MARK: - Cards

struct SeriesCard: View {
    let series: SeriesEntry
    let relatedNames: [String]
    let isCurrent: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                Thumbnail(url: series.coverURL, version: Int(series.modified.timeIntervalSince1970))
                    .frame(height: 250).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if series.chapters.isEmpty {
                    Image(systemName: "rectangle.stack.badge.plus").font(.largeTitle).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text("\(series.chapters.count) ch.")
                    .font(.caption.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white).padding(6)
            }
            .frame(height: 250)
            Text(series.info.name).font(.headline).lineLimit(2)
            ProgressView(value: series.chapters.isEmpty ? 0 : Double(series.translatedCount) / Double(series.chapters.count))
            Text("\(series.translatedCount)/\(series.chapters.count) chapters translated").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if !relatedNames.isEmpty {
                Label(relatedNames.count == 1 ? relatedNames[0] : "\(relatedNames.count) related series", systemImage: "link")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)).shadow(color: .black.opacity(hovering ? 0.18 : 0.06), radius: hovering ? 8 : 3, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2))
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Series \(series.info.name), \(series.chapters.count) chapters, \(series.translatedCount) translated")
    }
}

struct UnsortedCard: View {
    let chapters: [ChapterSummary]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(height: 250)
                .overlay(Image(systemName: "tray.full").font(.system(size: 44)).foregroundStyle(.secondary))
            Text("Unsorted").font(.headline)
            Text("\(chapters.count) chapter\(chapters.count == 1 ? "" : "s") without a series").font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .contentShape(Rectangle())
    }
}

struct NewSeriesCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus").font(.system(size: 36, weight: .light))
            Text("New Series").font(.headline)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity).frame(height: 330)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(.tertiary))
        .contentShape(Rectangle())
        .accessibilityLabel("New series")
    }
}

struct ChapterCard: View {
    let chapter: ChapterSummary
    let isOpen: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Thumbnail(url: chapter.coverURL, version: Int(chapter.modified.timeIntervalSince1970))
                    .frame(height: 230).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                StatusBadge(status: chapter.status).padding(6)
            }
            Text(chapter.displayTitle).font(.headline).lineLimit(1)
            if chapter.chapter == nil || chapter.series == nil { Text(chapter.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            ProgressView(value: chapter.progress).tint(chapter.status == .failed ? .red : chapter.status == .needsReview ? .orange : .accentColor)
            HStack {
                Text("\(chapter.translatedPages)/\(chapter.pageCount) pages").monospacedDigit()
                Spacer()
                Text("\(chapter.sourceLanguage == "auto" ? "Auto" : chapter.sourceLanguage.uppercased()) → \(chapter.targetLanguage.uppercased())")
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(chapter.modified, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)).shadow(color: .black.opacity(hovering ? 0.18 : 0.06), radius: hovering ? 8 : 3, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isOpen ? Color.accentColor : .clear, lineWidth: 2))
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chapter.displayTitle), \(chapter.status.displayName), \(chapter.translatedPages) of \(chapter.pageCount) pages translated")
    }
}

struct StatusBadge: View {
    let status: ChapterSummary.Status
    var body: some View {
        let (color, symbol): (Color, String) = switch status {
        case .translated: (.green, "checkmark.circle.fill")
        case .needsReview: (.orange, "exclamationmark.triangle.fill")
        case .inProgress: (.blue, "circle.lefthalf.filled")
        case .failed: (.red, "xmark.octagon.fill")
        case .notStarted, .empty: (.gray, "circle.dashed")
        }
        Label(status.displayName, systemImage: symbol)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.9), in: Capsule())
            .foregroundStyle(.white)
    }
}

/// Related series as clickable chips.
struct RelatedSeriesRow: View {
    let app: AppState
    let series: SeriesEntry
    let edit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Related series").font(.headline)
                Button(series.info.related.isEmpty ? "Add…" : "Edit…", action: edit).buttonStyle(.borderless)
            }
            if series.info.related.isEmpty {
                Text("Link sequels, prequels, spin-offs or series set in the same universe. Linked series can share their glossary so names stay consistent.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(series.info.related, id: \.seriesID) { r in
                            if let other = app.library.series(id: r.seriesID) {
                                Button { app.librarySelection = other.id } label: {
                                    HStack(spacing: 6) {
                                        Text(r.kind.displayName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        Text(other.info.name)
                                        if r.shareGlossary { Image(systemName: "character.book.closed").font(.caption).help("Shares glossary") }
                                        Text("\(other.chapters.count) ch.").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Editors

struct SeriesEditor: View {
    let app: AppState
    let target: SeriesEditorTarget
    @Environment(\.dismiss) private var dismiss
    @State private var info = SeriesInfo(name: "")
    @State private var altNames = ""
    @State private var relations: [SeriesRelation] = []
    @State private var useDefaults = true

    var existing: SeriesEntry? { if case .edit(let s) = target { return s }; return nil }
    var candidates: [SeriesEntry] { app.library.series.filter { $0.id != existing?.id } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(existing == nil ? "New Series" : "Series") {
                    TextField("Name", text: $info.name)
                    TextField("Alternate names (comma-separated)", text: $altNames)
                    Text("Original-language or alternate titles; files whose names match any of them are filed here.").font(.caption).foregroundStyle(.secondary)
                    TextField("Summary", text: $info.summary, axis: .vertical).lineLimit(2...4)
                }
                Section("Translation defaults for chapters") {
                    optionalPicker("Source", selection: $info.sourceLanguage, includeAuto: true)
                    optionalPicker("Target", selection: $info.targetLanguage, includeAuto: false)
                    Picker("Reading", selection: $info.readingDirection) {
                        Text("App default").tag(ReadingDirection?.none)
                        ForEach(ReadingDirection.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                    Picker("Tone", selection: $info.tone) {
                        Text("App default").tag(TranslationTone?.none)
                        ForEach(TranslationTone.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                    Picker("Honorifics", selection: $info.honorifics) {
                        Text("App default").tag(HonorificPolicy?.none)
                        ForEach(HonorificPolicy.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                }
                Section("Story & characters") {
                    TextEditor(text: $info.storyContext).frame(minHeight: 60)
                    Text("Sent to AI translators with every chapter of this series.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Related series") {
                    if candidates.isEmpty {
                        Text("Create another series to link it here.").foregroundStyle(.secondary)
                    }
                    ForEach($relations, id: \.seriesID) { $r in
                        HStack {
                            Picker("", selection: $r.kind) { ForEach(SeriesRelationKind.allCases) { Text($0.displayName).tag($0) } }
                                .labelsHidden().frame(width: 150)
                            Text(app.library.series(id: r.seriesID)?.info.name ?? "Missing series").lineLimit(1)
                            Spacer()
                            Toggle("Share glossary", isOn: $r.shareGlossary).toggleStyle(.checkbox)
                            Button { relations.removeAll { $0.seriesID == r.seriesID } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                    let available = candidates.filter { c in !relations.contains { $0.seriesID == c.id } }
                    if !available.isEmpty {
                        Menu("Add Related Series") {
                            ForEach(available) { c in
                                Menu(c.info.name) {
                                    ForEach(SeriesRelationKind.allCases) { k in
                                        Button(k.displayName) { relations.append(SeriesRelation(seriesID: c.id, kind: k)) }
                                    }
                                }
                            }
                        }.fixedSize()
                    }
                    Text("Links are two-way: adding a Sequel here shows this series as its Prequel.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if existing != nil { Text("\(existing!.chapters.count) chapters · \(info.glossary.count) glossary terms").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Create Series" : "Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(info.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding()
        }
        .frame(width: 560, height: 680)
        .onAppear {
            if let s = existing { info = s.info; relations = s.info.related; altNames = s.info.alternateNames.joined(separator: ", ") }
            else {
                let d = app.settings.stored.defaults
                info.sourceLanguage = d.sourceLanguage; info.targetLanguage = d.targetLanguage; info.readingDirection = d.readingDirection
            }
        }
    }

    func optionalPicker(_ label: String, selection: Binding<String?>, includeAuto: Bool) -> some View {
        Picker(label, selection: selection) {
            Text("App default").tag(String?.none)
            if includeAuto { Text("Auto-detect").tag(Optional("auto")) }
            ForEach(LanguageInfo.all) { Text($0.name).tag(Optional($0.code)) }
        }
    }

    func save() {
        info.name = info.name.trimmingCharacters(in: .whitespaces)
        info.alternateNames = altNames.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        app.saveSeries(info, existing: existing, relations: relations)
        dismiss()
    }
}

struct ChapterInfoSheet: View {
    let app: AppState
    let chapter: ChapterSummary
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var number = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Title", text: $title)
                TextField("Chapter number", text: $number)
                Text("Use right-click › Move to Series to change the series.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { app.updateChapterInfo(chapter.url, title: title, series: chapter.series ?? "", chapter: number); dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(width: 420)
        .onAppear { title = chapter.title; number = chapter.chapter ?? "" }
    }
}
