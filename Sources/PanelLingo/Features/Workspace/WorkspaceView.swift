import PanelLingoKit
import SwiftUI

struct WorkspaceView: View {
    @Bindable var app: AppState
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openSettings) private var openSettings
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            SidebarView(app: app)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            CanvasArea(app: app)
                .inspector(isPresented: $showInspector) {
                    InspectorView(app: app)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
                }
        }
        .navigationTitle(app.showLibrary || !app.hasProject ? "Library" : app.projectTitle)
        .navigationSubtitle(subtitle)
        .toolbar { MainToolbar(app: app, showInspector: $showInspector) }
        .onAppear {
            app.undoManager = undoManager
            if ProcessInfo.processInfo.arguments.contains("--open-settings") { openSettings() }
        }
        .onChange(of: undoManager) { _, u in app.undoManager = u }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in loadDrop(providers, app: app); return true }
        .alert(item: $app.alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .sheet(item: $app.consent) { c in CloudConsentSheet(request: c) { app.consent = nil } }
        .sheet(isPresented: $app.showOnboarding) { OnboardingView(app: app) }
        .sheet(isPresented: $app.showExport) { ExportSheet(app: app) }
        .sheet(isPresented: $app.showBatch) { BatchSheet(app: app) }
        .sheet(isPresented: $app.showGlossary) { GlossaryEditor(app: app) }
        .sheet(isPresented: $app.showProjectSettings) { ProjectSettingsSheet(app: app) }
        .onDeleteCommand { if app.editingRegionID == nil { app.deleteSelectedRegions() } }
        .onPasteCommand(of: [.image, .fileURL]) { _ in app.pasteFromClipboard() }
    }

    var subtitle: String {
        guard app.hasProject, !app.showLibrary else { return "" }
        let s = app.effectiveSettings
        let series = app.currentSeries.map { "\($0.info.name) · " } ?? ""
        return series + "\(LanguageInfo.name(s.sourceLanguage)) → \(LanguageInfo.name(s.targetLanguage)) · \(s.translationProvider.shortName)"
    }
}

struct MainToolbar: ToolbarContent {
    @Bindable var app: AppState
    @Binding var showInspector: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Toggle(isOn: Binding(get: { app.showLibrary || !app.hasProject }, set: { v in if app.hasProject { app.showLibrary = v } })) {
                Label("Library", systemImage: "books.vertical")
            }
            .help("Show all chapters (⇧⌘L)")
            Button {
                if app.showLibrary || !app.hasProject {
                    let sel = app.librarySelection
                    app.presentAddChaptersPanel(into: sel == AppState.unsortedID ? nil : sel)
                } else { app.presentImportPanel() }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Library: add chapters (one per PDF/CBZ/folder). Chapter: add pages to it (⌘O)")
        }
        if !(app.showLibrary || !app.hasProject) {
        ToolbarItemGroup(placement: .principal) {
            Picker("Display", selection: $app.displayMode) {
                ForEach(RenderMode.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 250)
            .help("Original / Cleaned / Translated")
            Menu {
                Picker("Compare", selection: $app.comparison) {
                    ForEach(ComparisonMode.allCases) { Text($0.displayName).tag($0) }
                }.pickerStyle(.inline)
                Toggle("Show Region Overlays", isOn: $app.showOverlays)
            } label: { Label("Compare", systemImage: "rectangle.split.2x1") }
            .help("Split or side-by-side comparison")
        }
        }
        ToolbarItemGroup {
            if !(app.showLibrary || !app.hasProject) {
            Picker("Tool", selection: $app.tool) {
                ForEach(CanvasTool.allCases) { t in Label(t.label, systemImage: t.symbol).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Canvas tool")
            .disabled(app.currentPage == nil)

            Menu {
                Button("Zoom In") { app.canvas.send(.zoomIn) }
                Button("Zoom Out") { app.canvas.send(.zoomOut) }
                Divider()
                Button("Fit Page") { app.canvas.send(.fitPage) }
                Button("Fit Width") { app.canvas.send(.fitWidth) }
                Button("Actual Pixels") { app.canvas.send(.actualSize) }
            } label: { Label("Zoom", systemImage: "plus.magnifyingglass") }

            Button { app.detectCurrentPage() } label: { Label("Detect Text", systemImage: "text.viewfinder") }
                .help("Detect panels and text regions")
                .disabled(app.currentPage == nil || app.isProcessingCurrentPage)

            Menu {
                Button("Translate Page") { app.translateCurrentPage() }
                Button("Translate Chapter…") { app.startBatch() }
                Divider()
                Button("Re-translate Page (keep approved)") { app.runPipeline(PipelineRequest(stages: [.translate, .typeset], force: true)) }
            } label: {
                Label("Translate Comic", systemImage: "character.bubble.fill")
            } primaryAction: { app.translateCurrentPage() }
            .help("Detect, OCR, translate, clean and typeset this page (⌘↩)")
            .disabled(app.currentPage == nil || app.isProcessingCurrentPage)

            Button { app.showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(app.pages.isEmpty)
            }
            SettingsLink { Label("Settings", systemImage: "gearshape") }
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
        }
    }
}

struct SidebarView: View {
    @Bindable var app: AppState
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        List(selection: $app.selectedPageID) {
            if app.hasProject {
                Section {
                    Button { app.showSeries(app.currentSeries?.id) } label: {
                        Label(app.currentSeries.map { "\($0.info.name)" } ?? "Library", systemImage: app.currentSeries == nil ? "books.vertical" : "chevron.left")
                    }.buttonStyle(.borderless).help("Show this chapter's series in the library")
                    HStack {
                        Image(systemName: "book.closed.fill").foregroundStyle(.tint)
                        Text(app.projectTitle).font(.headline).lineLimit(1)
                        Spacer()
                        Button { app.showProjectSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                            .buttonStyle(.borderless).help("Project settings")
                    }
                }
                if !app.searchText.isEmpty {
                    Section("Search Results") {
                        let results = app.searchResults()
                        if results.isEmpty { Text("No matches").foregroundStyle(.secondary) }
                        ForEach(results, id: \.region.id) { res in
                            Button { app.reveal(res.page.id, region: res.region.id) } label: {
                                VStack(alignment: .leading) {
                                    Text(res.region.translatedText ?? res.region.sourceText).lineLimit(1)
                                    Text("\(res.page.name) · \(res.region.sourceText)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Section("Pages (\(app.pages.count))") {
                    ForEach(app.pages) { page in
                        PageRow(app: app, page: page).tag(page.id)
                            .contextMenu {
                                Button("Rename…") { renaming = page.id; newName = page.name }
                                Button("Translate") { app.runPipeline(.full, pageID: page.id) }
                                Button("Retry Failed Stage") { app.runPipeline(.full, pageID: page.id) }.disabled(page.status != .failed)
                                Divider()
                                Button("Delete Page", role: .destructive) { app.deletePages([page.id]) }
                            }
                    }
                    .onMove { app.movePages(from: $0, to: $1) }
                    .onDelete { idx in app.deletePages(Set(idx.map { app.pages[$0].id })) }
                }
                if let page = app.currentPage, !page.regions.isEmpty {
                    Section("Text Regions") {
                        ForEach(page.orderedRegions) { r in
                            RegionRow(region: r, selected: app.selectedRegionIDs.contains(r.id))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if NSEvent.modifierFlags.contains(.command) { app.selectedRegionIDs.formSymmetricDifference([r.id]) }
                                    else { app.selectedRegionIDs = [r.id] }
                                }
                                .contextMenu { RegionContextMenu(app: app, region: r) }
                        }
                        .onMove { app.moveRegionsInOrder(from: $0, to: $1) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $app.searchText, placement: .sidebar, prompt: "Search dialogue")
        .alert("Rename Page", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let id = renaming { app.renamePage(id, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .safeAreaInset(edge: .bottom) {
            if let s = app.batchSnapshot, s.isRunning {
                Button { app.showBatch = true } label: {
                    HStack {
                        ProgressView(value: s.progress).controlSize(.small)
                        Text("\(s.finished)/\(s.order.count)").font(.caption.monospacedDigit())
                    }
                }.buttonStyle(.plain).padding(10)
            }
        }
    }
}

struct PageRow: View {
    let app: AppState
    let page: ComicPage
    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(url: app.store?.previewURL(page.id), version: page.completedStages.count + page.regions.count)
                .frame(width: 44, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                Text(page.name).lineLimit(1)
                HStack(spacing: 4) {
                    statusIcon
                    Text(page.status.displayName).font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(page.completedStages.count), total: Double(PipelineStage.allCases.count))
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder var statusIcon: some View {
        if app.pageTasks[page.id] != nil { ProgressView().controlSize(.mini) }
        else {
            switch page.status {
            case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .needsReview: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            default: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            }
        }
    }
}

struct Thumbnail: View {
    let url: URL?
    let version: Int
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            if let image { Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 3)) }
        }
        .task(id: "\(url?.path ?? "")#\(version)") {
            guard let url else { return }
            image = await Task.detached { NSImage(contentsOf: url) }.value
        }
    }
}

struct RegionRow: View {
    let region: TextRegion
    let selected: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(region.readingIndex + 1)").font(.caption.monospacedDigit().bold())
                .frame(width: 22, height: 22).background(Circle().fill(selected ? Color.accentColor : Color.secondary.opacity(0.25)))
                .foregroundStyle(selected ? .white : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(region.translatedText ?? (region.sourceText.isEmpty ? region.kind.displayName : region.sourceText)).lineLimit(2)
                if region.hasTranslation { Text(region.sourceText).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if region.review == .needsReview { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(region.reviewReasons.joined(separator: "\n")) }
            if region.locked { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
        .listRowBackground(selected ? Color.accentColor.opacity(0.15) : nil)
    }
}

struct DropTargetPlaceholder: View {
    let app: AppState
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 52)).foregroundStyle(.tertiary)
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary)
            HStack {
                Button("Import…") { app.presentImportPanel() }.keyboardShortcut("o")
                Button("Paste Image") { app.pasteFromClipboard() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in loadDrop(providers, app: app); return true }
    }
}

struct WelcomeView: View {
    let app: AppState
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "character.bubble.fill").font(.system(size: 64)).foregroundStyle(.tint)
            Text("PanelLingo").font(.largeTitle.bold())
            Text("Translate comics, manga, manhwa and webtoons — locally or with your AI provider.").foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button { app.newProject() } label: { Label("New Project", systemImage: "plus") }.controlSize(.large)
                Button { app.presentOpenPanel() } label: { Label("Open Project…", systemImage: "folder") }.controlSize(.large)
                Button { app.openSample() } label: { Label("Open Sample", systemImage: "sparkles") }.controlSize(.large)
            }
            Text("Or drop images, a PDF, a CBZ or a folder anywhere in this window.").font(.callout).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in loadDrop(providers, app: app); return true }
    }
}

struct CloudConsentSheet: View {
    let request: ConsentRequest
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Send content to \(request.provider.displayName)?", systemImage: "icloud.and.arrow.up").font(.title3.bold())
            Text("PanelLingo is about to send this project's content to a cloud service:")
            VStack(alignment: .leading, spacing: 6) {
                Label("Dialogue text (~\(request.characters) characters so far)", systemImage: "text.quote")
                if request.includesImages { Label("Page images or crops", systemImage: "photo") }
                else { Label("No images", systemImage: "photo").foregroundStyle(.secondary) }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Text("Requests count against your \(request.provider.shortName) account and may incur costs. Image sending and local-only mode are controlled in Settings › Privacy.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue") { dismiss(); request.proceed() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 460)
    }
}
