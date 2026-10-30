import PanelLingoKit
import SwiftUI
import UniformTypeIdentifiers

struct ExportSheet: View {
    @Bindable var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var format: ExportFormat = AppSettings.shared.stored.defaultExport
    @State private var scope = "all"
    @State private var quality = AppSettings.shared.stored.jpegQuality
    @State private var pattern = AppSettings.shared.stored.fileNamePattern
    @State private var mode: RenderMode = .translated
    @State private var progress: Double?
    @State private var result: String?

    var pages: [ComicPage] {
        scope == "current" ? app.currentPage.map { [$0] } ?? [] : app.pages
    }
    var issues: [String] { DefaultComicExportService.unresolvedIssues(pages) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Export") {
                    Picker("Format", selection: $format) { ForEach(ExportFormat.allCases) { Text($0.displayName).tag($0) } }
                    Picker("Pages", selection: $scope) {
                        Text("All pages (\(app.pages.count))").tag("all")
                        Text("Current page").tag("current")
                    }.pickerStyle(.radioGroup)
                    if [.png, .jpeg, .pdf, .cbz].contains(format) {
                        Picker("Content", selection: $mode) { ForEach(RenderMode.allCases) { Text($0.displayName).tag($0) } }
                    }
                    if format == .jpeg {
                        LabeledContent("JPEG quality") { HStack { Slider(value: $quality, in: 0.5...1); Text("\(Int(quality * 100))").monospacedDigit() } }
                    }
                    if format.producesFolder {
                        TextField("File names", text: $pattern)
                        Text("Tokens: {project} {page} {n} {nn} {nnn}").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Pages are exported at their original resolution without editor overlays.").font(.caption).foregroundStyle(.secondary)
                }
                if !issues.isEmpty {
                    Section("Unresolved items") {
                        ForEach(issues.prefix(8), id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
                        if issues.count > 8 { Text("…and \(issues.count - 8) more").font(.caption) }
                    }
                }
                if let progress { Section { ProgressView(value: progress) } }
                if let result { Section { Text(result).font(.callout).textSelection(.enabled) } }
            }.formStyle(.grouped)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { export() }.keyboardShortcut(.defaultAction).disabled(pages.isEmpty || progress != nil)
            }.padding()
        }
        .frame(width: 520, height: 560)
    }

    func export() {
        guard let store = app.store else { return }
        let dest: URL
        if format.producesFolder {
            let p = NSOpenPanel()
            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
            p.prompt = "Export Here"
            guard p.runModal() == .OK, let u = p.url else { return }
            dest = u
        } else {
            let p = NSSavePanel()
            p.nameFieldStringValue = "\(app.projectTitle).\(format.fileExtension)"
            p.canCreateDirectories = true
            if let t = UTType(filenameExtension: format.fileExtension) { p.allowedContentTypes = [t] }
            guard p.runModal() == .OK, let u = p.url else { return }
            dest = u
        }
        var opts = ExportOptions(format: format)
        opts.jpegQuality = quality; opts.fileNamePattern = pattern; opts.mode = mode
        AppSettings.shared.stored.defaultExport = format
        AppSettings.shared.stored.jpegQuality = quality
        AppSettings.shared.stored.fileNamePattern = pattern
        let selected = pages
        progress = 0; result = nil
        Task {
            do {
                let files = try await DefaultComicExportService().export(pages: selected, store: store, to: dest, options: opts) { p in
                    Task { @MainActor in self.progress = p }
                }
                progress = nil
                result = "Exported \(files.count) file\(files.count == 1 ? "" : "s") to \(dest.path)"
                NSWorkspace.shared.activateFileViewerSelecting(files.isEmpty ? [dest] : [files[0]])
            } catch {
                progress = nil
                result = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}

struct BatchSheet: View {
    @Bindable var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chapter Translation").font(.title2.bold())
            if let s = app.batchSnapshot {
                ProgressView(value: s.progress) {
                    Text("\(s.finished) of \(s.order.count) pages" + (s.failed > 0 ? " · \(s.failed) failed" : "") + (s.isPaused ? " · paused" : ""))
                }
                List(s.order, id: \.self) { id in
                    let page = app.pages.first { $0.id == id }
                    HStack {
                        Text(page?.name ?? id).lineLimit(1)
                        Spacer()
                        stateView(s.states[id] ?? .pending)
                    }
                }
                .frame(minHeight: 260)
                HStack {
                    if s.isRunning && !s.isPaused { Button("Pause") { Task { await app.batch?.pause() } } }
                    if s.isPaused { Button("Resume") { Task { await app.batch?.resume() } } }
                    if s.isRunning { Button("Cancel", role: .destructive) { Task { await app.batch?.cancel() } } }
                    if s.failed > 0 && !s.isRunning { Button("Retry Failed") { Task { await app.batch?.retryFailed() } } }
                    Spacer()
                    Button("Export…") { dismiss(); app.showExport = true }.disabled(s.isRunning)
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                Text("Completed stages are saved after each step; cancelling or quitting keeps finished work.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No batch is running.")
                HStack { Spacer(); Button("Translate All Pages") { app.startBatch() }; Button("Close") { dismiss() } }
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }

    @ViewBuilder func stateView(_ st: BatchQueue.ItemState) -> some View {
        switch st {
        case .pending: Text("Pending").foregroundStyle(.secondary)
        case .running(let s): HStack(spacing: 4) { ProgressView().controlSize(.small); Text(s.displayName) }
        case .done: Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .needsReview: Label("Needs review", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed(let m): Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red).help(m)
        case .skipped: Text("Already complete").foregroundStyle(.secondary)
        case .cancelled: Text("Cancelled").foregroundStyle(.secondary)
        }
    }
}

struct GlossaryEditor: View {
    @Bindable var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [GlossaryEntry] = []
    @State private var selection: Set<String> = []
    @State private var seriesScope = true

    var series: SeriesEntry? { app.currentSeries }

    var body: some View {
        VStack(spacing: 0) {
            if let series {
                HStack {
                    Picker("Glossary", selection: $seriesScope) {
                        Text("Series: \(series.info.name)").tag(true)
                        Text("This chapter only").tag(false)
                    }.pickerStyle(.segmented).fixedSize()
                    Spacer()
                    Text(seriesScope ? "Used for every chapter of the series" + (series.info.related.contains { $0.shareGlossary } ? " and shared with related series" : "")
                                     : "Overrides the series glossary for this chapter").font(.caption).foregroundStyle(.secondary)
                }
                .padding([.horizontal, .top])
                .onChange(of: seriesScope) { _, v in entries = v ? series.info.glossary : app.glossary }
            }
            Table($entries, selection: $selection) {
                TableColumn("Original") { $e in TextField("", text: $e.original) }
                TableColumn("Preferred") { $e in TextField("", text: $e.preferred) }
                TableColumn("Alternatives") { $e in
                    TextField("", text: Binding(get: { e.alternatives.joined(separator: ", ") },
                                                set: { e.alternatives = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                }
                TableColumn("Name") { $e in Toggle("", isOn: $e.isCharacterName).labelsHidden() }.width(44)
                TableColumn("Honorifics") { $e in TextField("", text: $e.honorificRule) }
                TableColumn("Notes") { $e in TextField("", text: $e.notes) }
                TableColumn("Aa") { $e in Toggle("", isOn: $e.caseSensitive).labelsHidden().help("Case sensitive") }.width(30)
            }
            HStack {
                Button { entries.append(GlossaryEntry(original: "", preferred: "")) } label: { Image(systemName: "plus") }
                Button { entries.removeAll { selection.contains($0.id) } } label: { Image(systemName: "minus") }.disabled(selection.isEmpty)
                Divider().frame(height: 16)
                Button("Import…") { importGlossary() }
                Menu("Export") {
                    Button("JSON…") { exportGlossary(csv: false) }
                    Button("CSV…") { exportGlossary(csv: true) }
                }.fixedSize()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let clean = entries.filter { !$0.original.isEmpty }
                    if series != nil && seriesScope { app.saveSeriesGlossary(clean) } else { app.saveGlossary(clean) }
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(width: 820, height: 480)
        .onAppear { seriesScope = series != nil; entries = series?.info.glossary ?? app.glossary }
    }

    func importGlossary() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json, .commaSeparatedText]
        guard p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url) else { return }
        do {
            let imported = url.pathExtension.lowercased() == "csv" ? GlossaryIO.parseCSV(String(decoding: data, as: UTF8.self))
                : try FileIO.decoder.decode([GlossaryEntry].self, from: data)
            // Never overwrite existing (approved) terms: only add new originals.
            let existing = Set(entries.map(\.original))
            entries += imported.filter { !existing.contains($0.original) }
        } catch { app.show(error, title: "Could not import glossary") }
    }

    func exportGlossary(csv: Bool) {
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(app.projectTitle) glossary.\(csv ? "csv" : "json")"
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let data = csv ? Data(GlossaryIO.csv(entries).utf8) : try FileIO.encoder.encode(entries)
            try FileIO.writeAtomically(data, to: url)
        } catch { app.show(error, title: "Could not export glossary") }
    }
}
