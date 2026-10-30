import Foundation
import Observation
import PanelLingoKit

/// App-wide preferences persisted in UserDefaults (API keys live in the Keychain, never here).
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    struct Stored: Codable {
        var defaults = ProjectSettings()
        var providers: [ProviderConfiguration] = ProviderKind.allCases.map { kind in
            var c = ProviderConfiguration(kind: kind)
            if kind == .ollama { c.model = "" }
            return c
        }
        var privacy = PrivacySettings()
        var processing = ProcessingSettings()
        var projectLocation: String = ""
        var autosave = true
        var defaultExport: ExportFormat = .png
        var jpegQuality = 0.92
        var fileNamePattern = "{project} - {nnn}"
        var onboardingDone = false
        var lastProjectPath: String?
        var includePageImage = false
        var cloudWarningAcknowledged: [String] = []
        var appearance: String = "system"
    }

    var stored: Stored { didSet { save() } }

    /// Test/demo runs (PANELLINGO_PROJECT_DIR set) use their own preferences so they never touch
    /// the installed app's settings or last-opened project.
    static let defaults: UserDefaults = {
        if ProcessInfo.processInfo.environment["PANELLINGO_PROJECT_DIR"] != nil,
           let d = UserDefaults(suiteName: "app.panellingo.PanelLingo.dev") { return d }
        return .standard
    }()

    private init() {
        if let d = Self.defaults.data(forKey: "settings.v1"), let s = try? JSONDecoder().decode(Stored.self, from: d) {
            stored = s
            // Add providers introduced in newer versions.
            for k in ProviderKind.allCases where !s.providers.contains(where: { $0.kind == k }) {
                stored.providers.append(ProviderConfiguration(kind: k))
            }
        } else {
            stored = Stored()
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(stored) { Self.defaults.set(d, forKey: "settings.v1") }
    }

    var projectLocation: URL {
        if let env = ProcessInfo.processInfo.environment["PANELLINGO_PROJECT_DIR"], !env.isEmpty { return URL(fileURLWithPath: env) }
        if !stored.projectLocation.isEmpty { return URL(fileURLWithPath: stored.projectLocation) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("PanelLingo")
    }

    var providerMap: [ProviderKind: ProviderConfiguration] {
        Dictionary(uniqueKeysWithValues: stored.providers.map { ($0.kind, $0) })
    }

    func provider(_ k: ProviderKind) -> ProviderConfiguration {
        stored.providers.first { $0.kind == k } ?? ProviderConfiguration(kind: k)
    }

    func update(_ k: ProviderKind, _ body: (inout ProviderConfiguration) -> Void) {
        guard let i = stored.providers.firstIndex(where: { $0.kind == k }) else { return }
        body(&stored.providers[i])
    }
}
