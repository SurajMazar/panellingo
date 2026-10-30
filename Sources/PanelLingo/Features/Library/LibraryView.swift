import PanelLingoKit
import SwiftUI

/// All chapters (projects) in the library folder, grouped by series, with translation progress.
struct LibraryView: View {
    @Bindable var app: AppState
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var sort: Sort = .series
    @State private var editing: ChapterSummary?
    @State private var confirmTrash: ChapterSummary?

    enum Filter: String, CaseIterable, Identifiable {
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

    enum Sort: String, CaseIterable, Identifiable {
        case series = "Series & Chapter", recent = "Recently Modified", title = "Title"
        var id: String { rawValue }
    }

    var filtered: [ChapterSummary] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return app.chapters.filter { c in
            filter.matches(c) && (q.isEmpty || c.title.localizedCaseInsensitiveContains(q) || (c.series ?? "").localizedCaseInsensitiveContains(q)
                                  || (c.chapter ?? "") == q)
        }
    }

    var groups: [(series: String, chapters: [ChapterSummary])] {
        switch sort {
        case .series:
            let byKey = Dictionary(grouping: filtered, by: \.seriesKey)
            return byKey.keys.sorted { a, b in
                if a == "Other chapters" { return false }
                if b == "Other chapters" { return true }
                return a.localizedStandardCompare(b) == .orderedAscending
            }.map { ($0, byKey[$0]!.sorted(by: ChapterLibrary.chapterOrder)) }
        case .recent: return [("Recently modified", filtered.sorted { $0.modified > $1.modified })]
        case .title: return [("All chapters", filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if app.chapters.isEmpty && !app.libraryLoading {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.series) { g in
                            Section {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 210), spacing: 18)], alignment: .leading, spacing: 20) {
                                    ForEach(g.chapters) { c in
                                        ChapterCard(chapter: c, isOpen: app.store?.url.standardizedFileURL == c.url.standardizedFileURL)
                                            .onTapGesture(count: 2) { app.openChapter(c) }
                                            .onTapGesture { app.openChapter(c) }
                                            .contextMenu { menu(c) }
                                    }
                                }
                                .padding(.horizontal, 24)
                            } header: {
                                SeriesHeader(name: g.series, chapters: g.chapters)
                            }
                        }
                    }
                    .padding(.vertical, 18)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .task { app.reloadLibrary() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in loadDrop(providers, app: app); return true }
        .sheet(item: $editing) { c in ChapterInfoSheet(app: app, chapter: c) }
        .confirmationDialog("Move “\(confirmTrash?.title ?? "")” to the Trash?", isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } })) {
            Button("Move to Trash", role: .destructive) { if let c = confirmTrash { app.trashChapter(c) }; confirmTrash = nil }
        } message: { Text("The project, including its original pages and translations, goes to the Trash. You can restore it from there.") }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Library").font(.title2.bold()).fixedSize()
                Text(summaryLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button { app.reloadLibrary() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh").buttonStyle(.borderless)
                Menu {
                    Button("Add Chapters…") { app.presentAddChaptersPanel() }
                    Button("Add Chapters and Translate…") { app.presentAddChaptersPanel(translate: true) }
                    Divider()
                    Button("Open Project…") { app.presentOpenPanel() }
                    Button("New Empty Chapter") { app.newProject() }
                    Button("Open Sample Project") { app.openSample() }
                    Divider()
                    Button("Show Library Folder in Finder") { app.revealInFinder(app.settings.projectLocation) }
                } label: { Label("Add Chapters", systemImage: "plus") } primaryAction: { app.presentAddChaptersPanel() }
                .fixedSize()
            }
            HStack(spacing: 12) {
                TextField("Search series or chapter", text: $search).textFieldStyle(.roundedBorder).frame(minWidth: 140, maxWidth: 260)
                Picker("Show", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }.fixedSize()
                Picker("Sort", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }.fixedSize()
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    var summaryLine: String {
        let done = app.chapters.filter { $0.status == .translated || $0.status == .needsReview }.count
        let series = Set(app.chapters.compactMap(\.series)).count
        return "\(app.chapters.count) chapter\(app.chapters.count == 1 ? "" : "s") · \(done) translated" + (series > 0 ? " · \(series) series" : "")
    }

    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical").font(.system(size: 54)).foregroundStyle(.tertiary)
            Text("No chapters yet").font(.title2.weight(.semibold))
            Text("Drop chapter PDFs, CBZ/CBR archives or folders of pages here. Each one becomes a chapter.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack {
                Button("Add Chapters…") { app.presentAddChaptersPanel() }.keyboardShortcut("o").controlSize(.large)
                Button("Open Sample") { app.openSample() }.controlSize(.large)
            }
            Text("Library folder: \(app.settings.projectLocation.path)").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder func menu(_ c: ChapterSummary) -> some View {
        Button("Open") { app.openChapter(c) }
        Button("Translate All Pages") { app.openChapter(c); app.startBatch() }.disabled(c.pageCount == 0)
        Button("Export…") { app.openChapter(c); app.showExport = true }.disabled(c.pageCount == 0)
        Divider()
        Button("Edit Series & Chapter…") { editing = c }
        Button("Show in Finder") { app.revealInFinder(c.url) }
        Divider()
        Button("Move to Trash…", role: .destructive) { confirmTrash = c }
    }
}

struct SeriesHeader: View {
    let name: String
    let chapters: [ChapterSummary]
    var body: some View {
        let done = chapters.filter { $0.status == .translated || $0.status == .needsReview }.count
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(.headline)
            Text("\(done)/\(chapters.count) translated").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 6)
        .background(.bar)
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
            if chapter.chapter != nil && chapter.series == nil { Text(chapter.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
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
        .accessibilityLabel("\(chapter.seriesKey), \(chapter.displayTitle), \(chapter.status.displayName), \(chapter.translatedPages) of \(chapter.pageCount) pages translated")
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

struct ChapterInfoSheet: View {
    let app: AppState
    let chapter: ChapterSummary
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var series = ""
    @State private var number = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Title", text: $title)
                TextField("Series", text: $series)
                TextField("Chapter", text: $number)
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { app.updateChapterInfo(chapter.url, title: title, series: series, chapter: number); dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(width: 420)
        .onAppear { title = chapter.title; series = chapter.series ?? ""; number = chapter.chapter ?? "" }
    }
}
