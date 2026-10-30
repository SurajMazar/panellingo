import PanelLingoKit
import SwiftUI

struct InspectorView: View {
    @Bindable var app: AppState
    var body: some View {
        Group {
            if let r = app.selectedRegion {
                RegionInspector(app: app, region: r).id(r.id)
            } else if app.selectedRegionIDs.count > 1 {
                MultiRegionInspector(app: app)
            } else if app.hasProject {
                PageInspector(app: app)
            } else {
                ContentUnavailableView("No Project", systemImage: "book.closed", description: Text("Create or open a project to begin."))
            }
        }
    }
}

// MARK: - Region

struct RegionInspector: View {
    @Bindable var app: AppState
    let region: TextRegion
    @State private var source = ""
    @State private var translation = ""
    @State private var compareProvider: ProviderKind = .ollama

    var body: some View {
        Form {
            Section {
                HStack {
                    Picker("Type", selection: Binding(get: { region.kind }, set: { k in app.updateRegion(region.id, "Change Region Type") { $0.kind = k } })) {
                        ForEach(RegionKind.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                LabeledContent("Reading order") {
                    Stepper("\(region.readingIndex + 1)", value: Binding(get: { region.readingIndex + 1 }, set: { v in
                        guard let page = app.currentPage else { return }
                        var ids = page.orderedRegions.map(\.id).filter { $0 != region.id }
                        ids.insert(region.id, at: min(max(0, v - 1), ids.count))
                        app.mutatePage(page.id, "Change Reading Order") { ReadingOrder.apply(order: ids, to: &$0) }
                    }), in: 1...max(1, app.currentPage?.regions.count ?? 1))
                }
                Toggle("Do not translate", isOn: Binding(get: { region.doNotTranslate }, set: { v in app.updateRegion(region.id, "Toggle Do Not Translate") { $0.doNotTranslate = v } }))
                Toggle("Lock region", isOn: Binding(get: { region.locked }, set: { v in app.updateRegion(region.id, "Toggle Lock") { $0.locked = v } }))
                if !region.reviewReasons.isEmpty || region.review == .needsReview {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(region.reviewReasons, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                        Button("Mark Reviewed") { app.updateRegion(region.id, "Approve Region") { $0.review = .approved; $0.reviewReasons = [] } }
                            .controlSize(.small)
                    }
                } else if region.review == .approved {
                    Label("Approved", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
            } header: { Text("Region") }

            Section {
                if let o = region.ocr {
                    LabeledContent("OCR text") { Text(o.text.isEmpty ? "—" : o.text).textSelection(.enabled).multilineTextAlignment(.trailing) }
                    LabeledContent("OCR confidence") { ConfidenceBadge(value: o.confidence) }
                    LabeledContent("Engine") { Text(o.engine).font(.caption) }
                    LabeledContent("Language") { Text(LanguageInfo.name(o.language ?? region.detectedLanguage ?? app.projectSettings.sourceLanguage)) }
                }
                VStack(alignment: .leading) {
                    Text("Corrected source text").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $source).font(.body).frame(minHeight: 54).scrollContentBackground(.hidden)
                        .padding(4).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Button("Save Correction") {
                        let v = source.trimmingCharacters(in: .whitespacesAndNewlines)
                        app.updateRegion(region.id, "Correct Source Text") { $0.correctedText = v == $0.ocr?.text ? nil : v }
                    }.disabled(source == region.sourceText)
                    Button("Re-run OCR") { app.rerunOCR([region.id]) }
                        .help("Re-recognises text; your corrected text is kept")
                }.controlSize(.small)
                if region.correctedText != nil {
                    Label("Using your corrected text", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Source") }

            Section {
                VStack(alignment: .leading) {
                    Text("Translation").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $translation).font(.body).frame(minHeight: 70).scrollContentBackground(.hidden)
                        .padding(4).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Button("Apply") {
                        let src = region.sourceText
                        app.updateRegion(region.id, "Edit Translation") { r in
                            if r.translation == nil {
                                r.translation = TranslationRecord(text: translation, provider: "manual", model: nil, modelConfidence: nil, reviewRequired: false, notes: nil, sourceText: src)
                            } else { r.translation?.text = translation }
                            r.translationLocked = true
                        }
                        if region.cleanup.status == .none { app.clean([region.id]) }
                    }.disabled(translation == (region.translatedText ?? ""))
                    Button("Re-translate") { app.retranslate([region.id]) }.disabled(region.sourceText.isEmpty)
                }.controlSize(.small)
                if let t = region.translation {
                    LabeledContent("Provider") { Text([ProviderKind(rawValue: t.provider)?.shortName ?? t.provider, t.model].compactMap { $0 }.joined(separator: " · ")).font(.caption) }
                    if let c = t.modelConfidence {
                        LabeledContent("Model confidence") { ConfidenceBadge(value: c) }.help("Self-reported by the model; not a calibrated probability")
                    }
                    if let n = t.notes { Text(n).font(.caption).foregroundStyle(.secondary) }
                    if region.translationIsStale { Label("Source changed since translation", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange) }
                    Toggle("Approved (skip automatic re-translation)", isOn: Binding(get: { region.translationLocked }, set: { v in app.updateRegion(region.id, "Approve Translation") { $0.translationLocked = v } }))
                }
                DisclosureGroup("Compare with another provider") {
                    HStack {
                        Picker("Provider", selection: $compareProvider) {
                            ForEach(ProviderKind.allCases) { Text($0.shortName).tag($0) }
                        }.labelsHidden()
                        Button("Translate") { app.compare(regionID: region.id, with: compareProvider) }.controlSize(.small)
                    }
                    ForEach(Array((app.alternatives[region.id] ?? []).enumerated()), id: \.offset) { _, alt in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(alt.text)
                            HStack {
                                Text(ProviderKind(rawValue: alt.provider)?.shortName ?? alt.provider).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Use") { app.useAlternative(alt, for: region.id) }.controlSize(.small)
                            }
                        }.padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            } header: { Text("Translation") }

            TypographySection(app: app, region: region)
            CleanupSection(app: app, region: region)
        }
        .formStyle(.grouped)
        .onAppear { source = region.sourceText; translation = region.translatedText ?? "" }
        .onChange(of: region.sourceText) { _, v in source = v }
        .onChange(of: region.translatedText) { _, v in translation = v ?? "" }
    }
}

struct TypographySection: View {
    @Bindable var app: AppState
    let region: TextRegion
    @State private var families: [String] = []

    func set(_ name: String, _ body: @escaping (inout TextStyle) -> Void) {
        app.updateRegion(region.id, name) { body(&$0.style) }
    }

    var body: some View {
        Section {
            Picker("Preset", selection: Binding(get: { region.style.presetID }, set: { id in
                if let p = TextStylePresets.preset(id) { set("Apply Lettering Preset") { s in let rot = s.rotation; s = p; s.rotation = rot } }
            })) {
                ForEach(TextStylePresets.all, id: \.id) { Text($0.name).tag($0.id) }
                if TextStylePresets.preset(region.style.presetID) == nil { Text("Custom").tag(region.style.presetID) }
            }
            Picker("Font", selection: Binding(get: { region.style.fontFamily }, set: { f in set("Change Font") { $0.fontFamily = f; $0.presetID = "custom" } })) {
                ForEach(["SF Pro Rounded", "System"] + families, id: \.self) { Text($0).tag($0) }
                if !families.contains(region.style.fontFamily) && !["SF Pro Rounded", "System"].contains(region.style.fontFamily) {
                    Text(region.style.fontFamily).tag(region.style.fontFamily)
                }
            }
            HStack {
                Toggle("Auto size", isOn: Binding(get: { region.style.fontSize == nil }, set: { auto in
                    let fitted = region.layout.fittedFontSize ?? 24
                    set("Toggle Auto Size") { $0.fontSize = auto ? nil : fitted }
                }))
                Spacer()
                if let s = region.style.fontSize {
                    Stepper("\(Int(s)) px", value: Binding(get: { s }, set: { v in set("Font Size") { $0.fontSize = max(4, v) } }), step: 1)
                } else if let f = region.layout.fittedFontSize {
                    Text("\(Int(f)) px").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Toggle("Bold", isOn: Binding(get: { region.style.bold }, set: { v in set("Bold") { $0.bold = v } }))
            Toggle("Italic", isOn: Binding(get: { region.style.italic }, set: { v in set("Italic") { $0.italic = v } }))
            Toggle("All caps", isOn: Binding(get: { region.style.uppercase }, set: { v in set("All Caps") { $0.uppercase = v } }))
            ColorPicker("Text color", selection: colorBinding(\.textColor, "Text Color"))
            ColorPicker("Outline color", selection: colorBinding(\.strokeColor, "Outline Color"))
            LabeledContent("Outline") {
                Slider(value: Binding(get: { region.style.strokeWidth }, set: { v in set("Outline Width") { $0.strokeWidth = v } }), in: 0...0.3)
            }
            Picker("Alignment", selection: Binding(get: { region.style.alignment }, set: { v in set("Alignment") { $0.alignment = v } })) {
                Image(systemName: "text.alignleft").tag(TextAlignmentOption.leading)
                Image(systemName: "text.aligncenter").tag(TextAlignmentOption.center)
                Image(systemName: "text.alignright").tag(TextAlignmentOption.trailing)
            }.pickerStyle(.segmented)
            Picker("Direction", selection: Binding(get: { region.style.direction }, set: { v in set("Text Direction") { $0.direction = v } })) {
                Text("Auto").tag(TextDirectionOption.auto)
                Text("Horizontal").tag(TextDirectionOption.horizontal)
                Text("Vertical (CJK)").tag(TextDirectionOption.vertical)
            }
            LabeledContent("Line spacing") {
                Slider(value: Binding(get: { region.style.lineSpacing }, set: { v in set("Line Spacing") { $0.lineSpacing = v } }), in: 0.7...1.6)
            }
            LabeledContent("Padding") {
                Slider(value: Binding(get: { region.style.padding }, set: { v in set("Bubble Padding") { $0.padding = v } }), in: 0...0.3)
            }
            LabeledContent("Rotation") {
                HStack {
                    Slider(value: Binding(get: { region.style.rotation }, set: { v in set("Rotation") { $0.rotation = v.rounded() } }), in: -45...45)
                    Text("\(Int(region.style.rotation))°").monospacedDigit().frame(width: 36)
                }
            }
            if region.layout.overflow { Label("Text does not fit — shorten it, reduce the minimum size or enlarge the region", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
        } header: { Text("Typography") }
        .task { families = TextStylePresets.installedFamilies() }
    }

    func colorBinding(_ kp: WritableKeyPath<TextStyle, RGBAColor>, _ name: String) -> Binding<Color> {
        Binding(get: {
            let c = region.style[keyPath: kp]
            return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
        }, set: { color in
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
            set(name) { $0[keyPath: kp] = RGBAColor(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent) }
        })
    }
}

struct CleanupSection: View {
    @Bindable var app: AppState
    let region: TextRegion
    var body: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 4) {
                    Text(region.cleanup.status.rawValue.capitalized)
                    if region.cleanup.manualMask { Text("· manual mask").foregroundStyle(.secondary) }
                }
            }
            if let m = region.cleanup.message { Text(m).font(.caption).foregroundStyle(.secondary) }
            LabeledContent("Mask expansion") {
                Stepper("\(Int(region.cleanup.maskExpansion)) px", value: Binding(get: { region.cleanup.maskExpansion }, set: { v in
                    app.updateRegion(region.id, "Mask Expansion") { $0.cleanup.maskExpansion = max(0, v) }
                }), in: 0...20)
            }
            LabeledContent("Feather") {
                Stepper("\(Int(region.cleanup.feather)) px", value: Binding(get: { region.cleanup.feather }, set: { v in
                    app.updateRegion(region.id, "Feather") { $0.cleanup.feather = max(0, v) }
                }), in: 0...10)
            }
            HStack {
                Button("Clean Text") { app.clean([region.id]) }
                Button("Restore Original") { app.restoreOriginal([region.id]) }
            }.controlSize(.small)
            HStack {
                Button { app.tool = .brush } label: { Label("Brush", systemImage: "paintbrush.pointed") }
                Button { app.tool = .eraser } label: { Label("Eraser", systemImage: "eraser") }
                if region.cleanup.manualMask { Button("Reset Mask") { app.resetMask(region.id) } }
            }.controlSize(.small)
            if app.tool == .brush || app.tool == .eraser {
                LabeledContent("Brush size") { Slider(value: $app.brushSize, in: 2...80) }
            }
        } header: { Text("Text Removal") }
    }
}

struct ConfidenceBadge: View {
    let value: Double
    var body: some View {
        Text("\(Int(value * 100))%")
            .font(.caption.monospacedDigit().bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((value >= 0.7 ? Color.green : value >= 0.45 ? Color.yellow : Color.orange).opacity(0.25), in: Capsule())
    }
}

struct MultiRegionInspector: View {
    @Bindable var app: AppState
    var body: some View {
        Form {
            Section("\(app.selectedRegionIDs.count) regions selected") {
                Button("Merge Regions") { app.mergeSelectedRegions() }
                Button("Translate Selected") { app.retranslate(app.selectedRegionIDs) }
                Button("Re-run OCR") { app.rerunOCR(app.selectedRegionIDs) }
                Button("Clean Text") { app.clean(app.selectedRegionIDs) }
                Button("Restore Original") { app.restoreOriginal(app.selectedRegionIDs) }
                Menu("Apply Lettering Preset") {
                    ForEach(TextStylePresets.all, id: \.id) { p in
                        Button(p.name) { app.updateSelectedRegions("Apply Lettering Preset") { $0.style = p.style } }
                    }
                }
                Button("Mark Reviewed") { app.updateSelectedRegions("Approve Regions") { $0.review = .approved; $0.reviewReasons = [] } }
                Button("Delete", role: .destructive) { app.deleteSelectedRegions() }
            }
        }.formStyle(.grouped)
    }
}

// MARK: - Page / Project

struct PageInspector: View {
    @Bindable var app: AppState
    var body: some View {
        Form {
            if let page = app.currentPage {
                Section("Page") {
                    LabeledContent("Name", value: page.name)
                    LabeledContent("Size", value: "\(page.pixelWidth) × \(page.pixelHeight) px")
                    LabeledContent("Status", value: page.status.displayName)
                    LabeledContent("Panels", value: "\(page.panels.count)")
                    LabeledContent("Regions", value: "\(page.regions.count)")
                    ForEach(PipelineStage.allCases, id: \.self) { s in
                        LabeledContent(s.displayName) {
                            Image(systemName: page.completedStages.contains(s) ? "checkmark.circle.fill" : "circle").foregroundStyle(page.completedStages.contains(s) ? .green : .secondary)
                        }
                    }
                    if let e = page.lastError {
                        Label("\(e.stage.displayName): \(e.message)", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
                        Button("Retry from \(e.stage.displayName)") { app.runPipeline(PipelineRequest(stages: PipelineStage.allCases.filter { $0 >= e.stage })) }
                    }
                    Button("Auto Reading Order") { app.reorderAutomatically(page.id) }
                }
            }
            ProjectLanguageSection(app: app)
            Section("Glossary") {
                LabeledContent("Entries", value: "\(app.glossary.count)")
                Button("Edit Glossary…") { app.showGlossary = true }
            }
        }
        .formStyle(.grouped)
    }
}

struct ProjectLanguageSection: View {
    @Bindable var app: AppState
    var body: some View {
        Section("Translation") {
            Picker("Source", selection: Binding(get: { app.projectSettings.sourceLanguage }, set: { v in app.updateProjectSettings { $0.sourceLanguage = v } })) {
                Text("Auto-detect").tag("auto")
                ForEach(LanguageInfo.all) { Text($0.name).tag($0.code) }
            }
            Picker("Target", selection: Binding(get: { app.projectSettings.targetLanguage }, set: { v in app.updateProjectSettings { $0.targetLanguage = v } })) {
                ForEach(LanguageInfo.all) { Text($0.name).tag($0.code) }
            }
            Picker("Reading", selection: Binding(get: { app.projectSettings.readingDirection }, set: { v in app.updateProjectSettings { $0.readingDirection = v } })) {
                ForEach(ReadingDirection.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Provider", selection: Binding(get: { app.projectSettings.translationProvider }, set: { v in
                app.updateProjectSettings { $0.translationProvider = v; $0.translationModel = AppSettings.shared.provider(v).model }
            })) {
                ForEach(ProviderKind.allCases) { k in
                    Text(k.displayName + (app.settings.stored.privacy.localOnly && !app.settings.provider(k).isLocal ? " (blocked: local-only)" : "")).tag(k)
                }
            }
            ModelPicker(app: app)
            Picker("Tone", selection: Binding(get: { app.projectSettings.tone }, set: { v in app.updateProjectSettings { $0.tone = v } })) {
                ForEach(TranslationTone.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Honorifics", selection: Binding(get: { app.projectSettings.honorifics }, set: { v in app.updateProjectSettings { $0.honorifics = v } })) {
                ForEach(HonorificPolicy.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("OCR", selection: Binding(get: { app.projectSettings.ocrEngine }, set: { v in app.updateProjectSettings { $0.ocrEngine = v } })) {
                ForEach(OCREngineKind.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Cleanup", selection: Binding(get: { app.projectSettings.cleanupMode }, set: { v in app.updateProjectSettings { $0.cleanupMode = v } })) {
                ForEach(CleanupMode.allCases) { Text($0.displayName).tag($0) }
            }
        }
    }
}

struct ModelPicker: View {
    @Bindable var app: AppState
    @State private var models: [String] = []
    @State private var status: String?
    var kind: ProviderKind { app.projectSettings.translationProvider }

    var body: some View {
        if kind.isLLM {
            HStack {
                if models.isEmpty {
                    TextField("Model", text: Binding(get: { app.projectSettings.translationModel }, set: { v in app.updateProjectSettings { $0.translationModel = v } }))
                } else {
                    Picker("Model", selection: Binding(get: { app.projectSettings.translationModel }, set: { v in app.updateProjectSettings { $0.translationModel = v } })) {
                        if !models.contains(app.projectSettings.translationModel) { Text(app.projectSettings.translationModel.isEmpty ? "Choose…" : app.projectSettings.translationModel).tag(app.projectSettings.translationModel) }
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Fetch available models")
            }
            .task(id: kind) { await refresh() }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }

    func refresh() async {
        let cfg = app.settings.provider(kind)
        let s = await TranslationEngine.defaultProvider(cfg).testConnection()
        models = s.models.isEmpty ? kind.suggestedModels : s.models
        status = s.ok ? nil : s.message
        if app.projectSettings.translationModel.isEmpty, let first = models.first { app.updateProjectSettings { $0.translationModel = first } }
    }
}

struct ProjectSettingsSheet: View {
    @Bindable var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Project") {
                    TextField("Title", text: $title).onSubmit { app.renameProject(title) }
                    LabeledContent("Location", value: app.store?.url.path ?? "—").font(.caption)
                    Button("Save As…") { app.presentSaveAs() }
                }
                ProjectLanguageSection(app: app)
                Section("Context for the translator") {
                    TextEditor(text: Binding(get: { app.projectSettings.storyContext }, set: { v in app.updateProjectSettings { $0.storyContext = v } }))
                        .frame(minHeight: 70)
                    Text("Characters, relationships, setting. Sent with LLM translation requests.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Custom instructions") {
                    TextEditor(text: Binding(get: { app.projectSettings.customInstructions }, set: { v in app.updateProjectSettings { $0.customInstructions = v } }))
                        .frame(minHeight: 60)
                    Toggle("Include previous page dialogue as context", isOn: Binding(get: { app.projectSettings.includePreviousPageContext }, set: { v in app.updateProjectSettings { $0.includePreviousPageContext = v } }))
                }
                Section("Default lettering") {
                    Picker("Preset", selection: Binding(get: { app.projectSettings.defaultStyle.presetID }, set: { id in
                        if let p = TextStylePresets.preset(id) { app.updateProjectSettings { $0.defaultStyle = p } }
                    })) { ForEach(TextStylePresets.all, id: \.id) { Text($0.name).tag($0.id) } }
                }
            }.formStyle(.grouped)
            HStack { Spacer(); Button("Done") { app.renameProject(title); dismiss() }.keyboardShortcut(.defaultAction) }.padding()
        }
        .frame(width: 520, height: 640)
        .onAppear { title = app.projectTitle }
    }
}
