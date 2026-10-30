import PanelLingoKit
import SwiftUI

/// Provider + model chooser. Lists the provider's real models (Ollama/LM Studio installed models,
/// cloud model lists) and falls back to a text field when the list can't be fetched.
struct ProviderModelPicker: View {
    let title: String
    @Binding var provider: ProviderKind
    @Binding var model: String
    /// Only offer providers/models that can read images (for AI Vision OCR).
    var visionOnly = false
    @State private var models: [String] = []
    @State private var status: String?
    @State private var loading = false

    var providers: [ProviderKind] { ProviderKind.allCases.filter { !visionOnly || $0.supportsVision } }

    var body: some View {
        Picker(title, selection: Binding(get: { provider }, set: { k in
            provider = k
            model = AppSettings.shared.provider(k).model
        })) {
            ForEach(providers) { k in
                let blocked = AppSettings.shared.stored.privacy.localOnly && !AppSettings.shared.provider(k).isLocal
                Text(k.displayName + (blocked ? " (blocked: local-only)" : "")).tag(k)
            }
        }
        if provider.isLLM {
            HStack {
                let shown = visionOnly ? models.filter(Self.looksVisionCapable) : models
                if shown.isEmpty {
                    TextField("Model", text: $model, prompt: Text(provider.suggestedModels.first ?? "model name"))
                } else {
                    Picker("Model", selection: $model) {
                        if !shown.contains(model) { Text(model.isEmpty ? "Choose…" : model).tag(model) }
                        ForEach(shown, id: \.self) { Text($0).tag($0) }
                    }
                }
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Fetch available models")
            }
            .task(id: provider) { await refresh() }
            if let status { Text(status).font(.caption).foregroundStyle(.orange) }
            if visionOnly && !models.isEmpty && models.filter(Self.looksVisionCapable).isEmpty {
                Text("None of the installed models look vision-capable. For Ollama, download e.g. qwen3-vl:8b in Settings › Local Models.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if provider == .apple {
            Text("On-device; no model to choose.").font(.caption).foregroundStyle(.secondary)
        }
    }

    static func looksVisionCapable(_ name: String) -> Bool {
        let n = name.lowercased()
        // Local model names reveal vision support; assume cloud chat models can read images.
        if ["vl", "vision", "llava", "gemma3", "minicpm-v", "moondream", "llama4", "pixtral", "gpt-4o", "gpt-4.1", "gpt-5", "claude", "gemini"].contains(where: n.contains) { return true }
        return false
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        let s = await TranslationEngine.defaultProvider(AppSettings.shared.provider(provider)).testConnection()
        models = s.models.isEmpty ? provider.suggestedModels : s.models
        status = s.ok ? nil : s.message
        if model.isEmpty, let first = (visionOnly ? models.filter(Self.looksVisionCapable) : models).first { model = first }
    }
}

/// Settings › Translation & OCR: the app-wide choices every chapter uses unless it overrides them.
struct TranslationOCRSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ProviderModelPicker(title: "Provider", provider: $settings.stored.defaults.translationProvider,
                                    model: $settings.stored.defaults.translationModel)
                Picker("Fallback provider", selection: $settings.stored.defaults.fallbackProvider) {
                    Text("None").tag(ProviderKind?.none)
                    ForEach(ProviderKind.allCases) { Text($0.shortName).tag(Optional($0)) }
                }
            } header: { Text("Translation") } footer: {
                Text("Used by every chapter unless the chapter is set to use its own settings. API keys and endpoints are under AI Providers.")
            }
            Section {
                Picker("Engine", selection: $settings.stored.defaults.ocrEngine) {
                    ForEach(OCREngineKind.allCases) { Text($0.displayName).tag($0) }
                }
                if settings.stored.defaults.ocrEngine == .aiVision {
                    Toggle("Use the translation model for OCR", isOn: Binding(
                        get: { settings.stored.defaults.ocrProvider == nil },
                        set: { same in
                            if same { settings.stored.defaults.ocrProvider = nil; settings.stored.defaults.ocrModel = nil }
                            else {
                                let k: ProviderKind = settings.stored.defaults.translationProvider.supportsVision ? settings.stored.defaults.translationProvider : .ollama
                                settings.stored.defaults.ocrProvider = k
                                settings.stored.defaults.ocrModel = settings.provider(k).model
                            }
                        }))
                    if settings.stored.defaults.ocrProvider != nil {
                        ProviderModelPicker(title: "OCR provider",
                                            provider: Binding(get: { settings.stored.defaults.ocrProvider ?? .ollama }, set: { settings.stored.defaults.ocrProvider = $0 }),
                                            model: Binding(get: { settings.stored.defaults.ocrModel ?? "" }, set: { settings.stored.defaults.ocrModel = $0 }),
                                            visionOnly: true)
                    } else if !settings.stored.defaults.translationProvider.supportsVision {
                        Label("\(settings.stored.defaults.translationProvider.shortName) can't read images. Turn off the toggle above and pick a vision model (e.g. Ollama qwen3-vl).",
                              systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    }
                }
            } header: { Text("OCR") } footer: {
                Text("Apple Vision is fast and on-device. AI Vision sends each bubble crop to a vision model — better for handwritten or stylised lettering. Cloud OCR needs Privacy › Allow sending images.")
            }
        }
        .formStyle(.grouped)
    }
}
