import PanelLingoKit
import SwiftUI
import Translation

struct SettingsView: View {
    @Bindable var settings = AppSettings.shared
    /// Settings always open on Translation & OCR, the setting people change most.
    @State private var tab = "translation"
    var body: some View {
        TabView(selection: $tab) {
            TranslationOCRSettings(settings: settings).tabItem { Label("Translation & OCR", systemImage: "character.bubble") }.tag("translation")
            GeneralSettings(settings: settings).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            LanguageSettings(settings: settings).tabItem { Label("Languages", systemImage: "globe") }.tag("languages")
            ProviderSettings(settings: settings).tabItem { Label("AI Providers", systemImage: "sparkles") }.tag("providers")
            LocalModelSettings(settings: settings).tabItem { Label("Local Models", systemImage: "cpu") }.tag("local")
            OCRSettings(settings: settings).tabItem { Label("OCR", systemImage: "doc.text.viewfinder") }.tag("ocr")
            TypesettingSettings(settings: settings).tabItem { Label("Typesetting", systemImage: "textformat") }.tag("typesetting")
            ProcessingSettingsView(settings: settings).tabItem { Label("Processing", systemImage: "speedometer") }.tag("processing")
            PrivacySettingsView(settings: settings).tabItem { Label("Privacy", systemImage: "hand.raised") }.tag("privacy")
        }
        .frame(width: 680, height: 540)
    }
}

struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            LabeledContent("Project location") {
                HStack {
                    Text(settings.projectLocation.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                        if p.runModal() == .OK, let u = p.url { settings.stored.projectLocation = u.path }
                    }
                }
            }
            Picker("Appearance", selection: $settings.stored.appearance) {
                Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }
            Toggle("Autosave every change", isOn: .constant(true)).disabled(true)
                .help("Projects are saved atomically after every edit and pipeline stage.")
            Picker("Default export format", selection: $settings.stored.defaultExport) {
                ForEach(ExportFormat.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Default reading direction", selection: $settings.stored.defaults.readingDirection) {
                ForEach(ReadingDirection.allCases) { Text($0.displayName).tag($0) }
            }
            Button("Show Onboarding Again") { settings.stored.onboardingDone = false }
        }.formStyle(.grouped)
    }
}

struct LanguageSettings: View {
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            Picker("Default source", selection: $settings.stored.defaults.sourceLanguage) {
                Text("Auto-detect").tag("auto")
                ForEach(LanguageInfo.all) { Text($0.name).tag($0.code) }
            }
            Picker("Default target", selection: $settings.stored.defaults.targetLanguage) {
                ForEach(LanguageInfo.all) { Text($0.name).tag($0.code) }
            }
            Picker("Honorifics", selection: $settings.stored.defaults.honorifics) {
                ForEach(HonorificPolicy.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Translation tone", selection: $settings.stored.defaults.tone) {
                ForEach(TranslationTone.allCases) { Text($0.displayName).tag($0) }
            }
            Section("Default custom instructions") {
                TextEditor(text: $settings.stored.defaults.customInstructions).frame(minHeight: 80)
            }
            Text("These defaults apply to new projects; each project can override them.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

struct ProviderSettings: View {
    @Bindable var settings: AppSettings
    @State private var selected: ProviderKind = .ollama
    @State private var key = ""
    @State private var status: ProviderStatus?
    @State private var testing = false

    var body: some View {
        HSplitView {
            List(ProviderKind.allCases, selection: $selected) { k in
                HStack {
                    Text(k.shortName)
                    Spacer()
                    if k.requiresAPIKey { Image(systemName: KeychainStore.has(k) ? "key.fill" : "key").foregroundStyle(KeychainStore.has(k) ? .green : .secondary) }
                    if settings.provider(k).isLocal { Image(systemName: "lock.laptopcomputer").foregroundStyle(.secondary).help("Runs on this Mac") }
                }.tag(k)
            }.frame(minWidth: 170, maxWidth: 200)
            Form {
                let binding = Binding(get: { settings.provider(selected) }, set: { v in settings.update(selected) { $0 = v } })
                Section(selected.displayName) {
                    if selected != .apple {
                        TextField("Endpoint", text: binding.baseURL)
                    }
                    if selected.requiresAPIKey {
                        SecureField("API key", text: $key, prompt: Text(KeychainStore.has(selected) ? "•••••••• (stored in Keychain)" : "Paste API key"))
                        HStack {
                            Button("Save Key") { saveKey() }.disabled(key.isEmpty)
                            Button("Remove Key", role: .destructive) { try? KeychainStore.set(nil, for: selected); key = ""; status = nil }
                                .disabled(!KeychainStore.has(selected))
                        }
                    }
                    if selected.isLLM {
                        HStack {
                            TextField("Model", text: binding.model)
                            if let models = status?.models, !models.isEmpty {
                                Menu("Choose") { ForEach(models, id: \.self) { m in Button(m) { settings.update(selected) { $0.model = m } } } }.fixedSize()
                            }
                        }
                        LabeledContent("Temperature") { Slider(value: binding.temperature, in: 0...1.2) { Text("") } }
                    }
                    Stepper("Timeout: \(Int(binding.wrappedValue.timeoutSeconds)) s", value: binding.timeoutSeconds, in: 10...600, step: 10)
                    Stepper("Retries: \(binding.wrappedValue.retryCount)", value: binding.retryCount, in: 0...6)
                    Stepper("Requests/minute: \(binding.wrappedValue.requestsPerMinute == 0 ? "unlimited" : String(binding.wrappedValue.requestsPerMinute))", value: binding.requestsPerMinute, in: 0...600, step: 5)
                    Stepper("Max characters/request: \(binding.wrappedValue.maxCharactersPerRequest)", value: binding.maxCharactersPerRequest, in: 500...40000, step: 500)
                }
                Section {
                    HStack {
                        Button("Test Connection") { test() }.disabled(testing)
                        if testing { ProgressView().controlSize(.small) }
                    }
                    if let s = status { Label(s.message, systemImage: s.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(s.ok ? .green : .red) }
                    Text(selected.isLocal(baseURL: settings.provider(selected).baseURL) ? "Runs locally: nothing leaves this Mac." :
                            "Cloud provider: text (and images, if allowed in Privacy) is sent to \(selected.shortName). You'll be asked before the first request in each session.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
        .onChange(of: selected) { _, _ in key = ""; status = nil }
    }

    func saveKey() {
        do { try KeychainStore.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: selected); key = ""; test() }
        catch { status = ProviderStatus(ok: false, message: error.localizedDescription) }
    }

    func test() {
        testing = true
        let cfg = settings.provider(selected)
        Task {
            status = await TranslationEngine.defaultProvider(cfg).testConnection()
            testing = false
        }
    }
}

struct LocalModelSettings: View {
    @Bindable var settings: AppSettings
    @State private var models: [OllamaManager.Model] = []
    @State private var error: String?
    @State private var pullName = "qwen3-vl:8b"
    @State private var pullProgress: (Double?, String)?
    @State private var appleLanguages: [String] = []

    var manager: OllamaManager { OllamaManager(baseURL: settings.provider(.ollama).baseURL) }

    var body: some View {
        Form {
            Section("Ollama") {
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                ForEach(models) { m in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(m.name)
                            Text([m.parameterSize, m.family, ByteCountFormatter.string(fromByteCount: m.sizeBytes, countStyle: .file)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if m.isVisionCapable { Image(systemName: "eye").help("Vision-capable: usable for AI Vision OCR") }
                        Spacer()
                        Button("Use") { settings.update(.ollama) { $0.model = m.name } }.disabled(settings.provider(.ollama).model == m.name)
                        Button(role: .destructive) { Task { try? await manager.delete(m.name); await refresh() } } label: { Image(systemName: "trash") }
                    }
                }
                LabeledContent("Disk usage", value: ByteCountFormatter.string(fromByteCount: models.reduce(0) { $0 + $1.sizeBytes }, countStyle: .file))
                HStack {
                    TextField("Model to download", text: $pullName)
                    Button("Download") { pull() }.disabled(pullProgress != nil || pullName.isEmpty)
                }
                if let (p, s) = pullProgress {
                    if let p { ProgressView(value: p) { Text(s).font(.caption) } } else { ProgressView { Text(s).font(.caption) } }
                }
                Text("Downloads need internet once; afterwards translation runs fully offline. qwen3-vl:8b is ~6 GB and needs ~8 GB of free memory; on 8 GB Macs prefer qwen3-vl:4b (~3 GB).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Refresh") { Task { await refresh() } }
            }
            Section("Apple Translation language packs") {
                Text("Supported on this Mac: \(appleLanguages.joined(separator: ", "))").font(.caption)
                AppleLanguagePackRow(source: settings.stored.defaults.sourceLanguage == "auto" ? "ja" : settings.stored.defaults.sourceLanguage,
                                     target: settings.stored.defaults.targetLanguage)
            }
            Section("Neural inpainting") {
                Label("Not installed — Balanced (diffusion) cleanup is used instead.", systemImage: "info.circle")
                Text("PanelLingo does not bundle a neural inpainting model. Expected path: \(CoreMLInpainter.modelURL.path)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refresh(); appleLanguages = await AppleTranslationProvider.supportedLanguages() }
    }

    func refresh() async {
        do { models = try await manager.models(); error = nil } catch {
            models = []
            self.error = "Ollama is not reachable at \(settings.provider(.ollama).baseURL). Install it from ollama.com and launch it."
        }
    }

    func pull() {
        pullProgress = (nil, "Starting…")
        let name = pullName
        Task {
            do {
                try await manager.pull(name) { p, s in Task { @MainActor in self.pullProgress = (p, s) } }
                pullProgress = nil
                await refresh()
            } catch { pullProgress = nil; self.error = error.localizedDescription }
        }
    }
}

/// Shows Apple Translation availability for a pair and triggers the system download prompt.
struct AppleLanguagePackRow: View {
    let source: String
    let target: String
    @State private var status: AppleTranslationProvider.PairStatus?
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        HStack {
            Text("\(LanguageInfo.name(source)) → \(LanguageInfo.name(target))")
            Spacer()
            switch status {
            case .installed: Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .downloadable:
                Button("Download…") {
                    config = TranslationSession.Configuration(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
                }
            case .unsupported: Label("Unsupported", systemImage: "xmark.circle").foregroundStyle(.secondary)
            case nil: ProgressView().controlSize(.small)
            }
        }
        .task(id: source + target) { status = await AppleTranslationProvider.status(source: source, target: target) }
        .translationTask(config) { session in
            try? await session.prepareTranslation()
            let s = await AppleTranslationProvider.status(source: source, target: target)
            await MainActor.run { status = s }
        }
    }
}

struct OCRSettings: View {
    @Bindable var settings: AppSettings
    @State private var langs: [String] = []
    var body: some View {
        Form {
            Text("Choose the OCR engine and model in Translation & OCR.").font(.callout).foregroundStyle(.secondary)
            LabeledContent("Detection sensitivity") {
                Slider(value: $settings.stored.processing.detectionSensitivity, in: 0...1) { Text("") } minimumValueLabel: { Text("Strict") } maximumValueLabel: { Text("Loose") }
            }
            Section("Apple Vision languages on this Mac") {
                Text(langs.joined(separator: ", ")).font(.callout).textSelection(.enabled)
                Text("Vertical Japanese/Chinese is read by slicing columns into glyphs and re-laying them horizontally. Languages not listed (e.g. Hindi, Nepali) need the AI Vision OCR engine with a vision-capable model.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Preprocessing (contrast stretch, upscaling of small text, masking of bubble borders) is applied automatically.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task { langs = VisionLanguages.supported() }
    }
}

struct TypesettingSettings: View {
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            Picker("Default lettering preset", selection: Binding(get: { settings.stored.defaults.defaultStyle.presetID }, set: { id in
                if let p = TextStylePresets.preset(id) { settings.stored.defaults.defaultStyle = p }
            })) { ForEach(TextStylePresets.all, id: \.id) { Text($0.name).tag($0.id) } }
            Stepper("Minimum font size: \(Int(settings.stored.defaults.defaultStyle.minFontSize)) px", value: $settings.stored.defaults.defaultStyle.minFontSize, in: 4...40)
            Stepper("Maximum font size: \(Int(settings.stored.defaults.defaultStyle.maxFontSize)) px", value: $settings.stored.defaults.defaultStyle.maxFontSize, in: 16...300, step: 4)
            Picker("Alignment", selection: $settings.stored.defaults.defaultStyle.alignment) {
                Text("Leading").tag(TextAlignmentOption.leading); Text("Center").tag(TextAlignmentOption.center); Text("Trailing").tag(TextAlignmentOption.trailing)
            }
            LabeledContent("Bubble padding") { Slider(value: $settings.stored.defaults.defaultStyle.padding, in: 0...0.3) }
            Text("Presets use fonts that ship with macOS. Any installed font can be chosen per region in the inspector.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

struct ProcessingSettingsView: View {
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            Stepper("Concurrent pages (cloud / Apple): \(settings.stored.processing.concurrentPages)", value: $settings.stored.processing.concurrentPages, in: 1...8)
            Stepper("Concurrent pages (local models): \(settings.stored.processing.concurrentLocalInference)", value: $settings.stored.processing.concurrentLocalInference, in: 1...4)
            Text("This Mac has \(ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)) of memory. Local LLMs run best one page at a time.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Default cleanup", selection: $settings.stored.defaults.cleanupMode) {
                ForEach(CleanupMode.allCases) { Text($0.displayName).tag($0) }
            }
            LabeledContent("Flag OCR below") { Slider(value: $settings.stored.processing.reviewOCRConfidenceThreshold, in: 0...1) }
            LabeledContent("Flag translation below") { Slider(value: $settings.stored.processing.reviewTranslationConfidenceThreshold, in: 0...1) }
            Stepper("Max working pixels: \(settings.stored.processing.maxWorkingPixels / 1_000_000) MP", value: $settings.stored.processing.maxWorkingPixels, in: 4_000_000...120_000_000, step: 4_000_000)
        }.formStyle(.grouped)
    }
}

struct PrivacySettingsView: View {
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            Toggle("Local-only mode", isOn: $settings.stored.privacy.localOnly)
            Text("When on, PanelLingo never sends text or images to cloud providers. Apple Translation, Ollama and LM Studio still work.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Allow sending dialogue text to cloud providers", isOn: $settings.stored.privacy.allowSendingText).disabled(settings.stored.privacy.localOnly)
            Toggle("Allow sending images / crops to cloud providers", isOn: $settings.stored.privacy.allowSendingImages).disabled(settings.stored.privacy.localOnly)
            Toggle("Send page image as translation context (vision models)", isOn: $settings.stored.includePageImage)
            Toggle("Verbose diagnostic logging", isOn: $settings.stored.privacy.verboseLogging)
            Text("PanelLingo has no telemetry and no account. API keys are stored only in the macOS Keychain, are never written to projects or exports, and are redacted from logs.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}
