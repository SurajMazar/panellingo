import Foundation

/// Local model management for Ollama: list (with disk usage), pull with progress, delete.
public struct OllamaManager: Sendable {
    public struct Model: Sendable, Identifiable, Hashable {
        public var name: String
        public var sizeBytes: Int64
        public var parameterSize: String?
        public var family: String?
        public var id: String { name }
        public var isVisionCapable: Bool {
            let n = name.lowercased()
            return ["vl", "vision", "llava", "gemma3", "minicpm-v", "moondream", "qwen2.5vl", "llama4"].contains { n.contains($0) }
        }
    }

    public var baseURL: String
    public init(baseURL: String = ProviderKind.ollama.defaultBaseURL) { self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }

    func url(_ path: String) throws -> URL {
        guard let u = URL(string: baseURL + path) else { throw PanelLingoError.provider(.ollama, .notConfigured("invalid URL")) }
        return u
    }

    public func models() async throws -> [Model] {
        let o = try await HTTPClient(timeout: 10).json("GET", url: url("/api/tags"), provider: .ollama)
        return ((o["models"] as? [[String: Any]]) ?? []).compactMap { m in
            guard let name = m["name"] as? String else { return nil }
            let details = m["details"] as? [String: Any]
            return Model(name: name, sizeBytes: (m["size"] as? NSNumber)?.int64Value ?? 0,
                         parameterSize: details?["parameter_size"] as? String, family: details?["family"] as? String)
        }.sorted { $0.name < $1.name }
    }

    public func delete(_ name: String) async throws {
        _ = try await HTTPClient(timeout: 30).send("DELETE", url: url("/api/delete"), json: ["model": name], provider: .ollama)
    }

    /// Streams pull progress (0…1, status text).
    public func pull(_ name: String, progress: @escaping @Sendable (Double?, String) -> Void) async throws {
        var req = URLRequest(url: try url("/api/pull"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
        req.timeoutInterval = 3600
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let h = response as? HTTPURLResponse, h.statusCode >= 400 {
            throw PanelLingoError.provider(.ollama, .server(h.statusCode, "pull failed"))
        }
        for try await line in bytes.lines {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let e = o["error"] as? String { throw PanelLingoError.provider(.ollama, .server(500, e)) }
            let status = o["status"] as? String ?? ""
            let total = (o["total"] as? NSNumber)?.doubleValue, done = (o["completed"] as? NSNumber)?.doubleValue
            progress(total.flatMap { t in done.map { t > 0 ? $0 / t : 0 } }, status)
        }
    }
}
