import PanelLingoKit
import SwiftUI

struct OnboardingView: View {
    @Bindable var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var provider: ProviderKind = .apple
    @State private var ollamaStatus: ProviderStatus?
    @State private var target = "en"
    @State private var direction: ReadingDirection = .rightToLeft

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: providerStep
                case 2: languageStep
                default: startStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
            Divider()
            HStack {
                HStack(spacing: 6) { ForEach(0..<4) { i in Circle().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7) } }
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                if step < 3 { Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction) }
                else { Button("Done") { finish() }.keyboardShortcut(.defaultAction) }
            }.padding()
        }
        .frame(width: 620, height: 470)
    }

    var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "character.bubble.fill").font(.system(size: 60)).foregroundStyle(.tint)
            Text("Welcome to PanelLingo").font(.largeTitle.bold())
            Text("Import a comic, manga, manhwa or webtoon page and translate it with one click. PanelLingo detects bubbles, reads the text, translates it with context, removes the original lettering and typesets the translation — keeping your original artwork untouched.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 480)
            HStack(spacing: 22) {
                feature("text.viewfinder", "Detect")
                feature("doc.text.magnifyingglass", "OCR")
                feature("globe", "Translate")
                feature("eraser", "Clean")
                feature("textformat", "Typeset")
            }.padding(.top, 8)
        }
    }

    func feature(_ symbol: String, _ title: String) -> some View {
        VStack { Image(systemName: symbol).font(.title2).foregroundStyle(.tint); Text(title).font(.caption) }
    }

    var providerStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Translation Setup").font(.title.bold())
            Text("Choose how PanelLingo translates. You can change this any time; no account is required for local options.").foregroundStyle(.secondary)
            Picker("", selection: $provider) {
                Label("Apple Translation — on-device, private, offline once languages are downloaded", systemImage: "apple.logo").tag(ProviderKind.apple)
                Label("Ollama — local AI model, context-aware, private", systemImage: "cpu").tag(ProviderKind.ollama)
                Label("LM Studio — local AI model via its server", systemImage: "desktopcomputer").tag(ProviderKind.lmStudio)
                Label("Cloud AI (OpenAI, Anthropic, Gemini, OpenRouter, DeepL)", systemImage: "icloud").tag(ProviderKind.openAI)
            }.pickerStyle(.radioGroup).labelsHidden()
            Group {
                switch provider {
                case .apple:
                    Text("Language packs are downloaded by macOS the first time (Settings › Local Models shows their status).")
                case .ollama:
                    if let s = ollamaStatus { Label(s.message, systemImage: s.ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(s.ok ? .green : .orange) }
                    else { ProgressView().controlSize(.small) }
                    Text("Install Ollama from ollama.com, then pull a model (e.g. qwen3-vl:8b, ~6 GB) in Settings › Local Models.")
                case .lmStudio:
                    Text("Start LM Studio's local server (default http://localhost:1234) and load a model.")
                default:
                    Text("Add your API key in Settings › AI Providers. Keys are stored in the macOS Keychain. You'll be asked before any content is sent.")
                }
            }.font(.callout).foregroundStyle(.secondary)
        }
        .task(id: provider) {
            if provider == .ollama { ollamaStatus = await LLMTranslationProvider(configuration: app.settings.provider(.ollama)).testConnection() }
        }
    }

    var languageStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Language Preferences").font(.title.bold())
            Form {
                Picker("Translate into", selection: $target) { ForEach(LanguageInfo.all) { Text($0.name).tag($0.code) } }
                Picker("Usual reading direction", selection: $direction) { ForEach(ReadingDirection.allCases) { Text($0.displayName).tag($0) } }
            }.formStyle(.grouped)
            Text("Source language is detected automatically, or set it per project.").font(.callout).foregroundStyle(.secondary)
        }
    }

    var startStep: some View {
        VStack(spacing: 16) {
            Text("Start Translating").font(.title.bold())
            RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(.secondary)
                .overlay(VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Drop comic pages here")
                })
                .frame(height: 170)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in finish(); loadDrop(providers, app: app); return true }
            HStack {
                Button("Choose Files…") { finish(); app.presentImportPanel() }
                Button("Open Sample Project") { finish(); app.openSample() }
            }
        }
    }

    func finish() {
        app.settings.stored.onboardingDone = true
        app.settings.stored.defaults.translationProvider = provider
        app.settings.stored.defaults.targetLanguage = target
        app.settings.stored.defaults.readingDirection = direction
        if provider == .ollama, let m = ollamaStatus?.models.first {
            app.settings.update(.ollama) { $0.model = m }
            app.settings.stored.defaults.translationModel = m
        }
        if app.hasProject {
            app.updateProjectSettings { $0.translationProvider = provider; $0.targetLanguage = target; $0.readingDirection = direction
                if provider == .ollama, let m = ollamaStatus?.models.first { $0.translationModel = m } }
        }
        dismiss()
    }
}
