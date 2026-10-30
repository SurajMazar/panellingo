import Foundation
import Security

/// Minimal JSON HTTP client with provider-aware error mapping and secret redaction.
public struct HTTPClient: Sendable {
    public var timeout: Double
    public var session: URLSession

    public init(timeout: Double = 120, session: URLSession? = nil) {
        self.timeout = timeout
        if let session { self.session = session } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = timeout
            cfg.timeoutIntervalForResource = timeout * 2
            cfg.httpAdditionalHeaders = ["User-Agent": "PanelLingo/\(PanelLingoVersion.string)"]
            self.session = URLSession(configuration: cfg)
        }
    }

    public func send(_ method: String = "POST", url: URL, headers: [String: String] = [:], json: Any? = nil,
                     provider: ProviderKind) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        Log.network.debug("\(method, privacy: .public) \(Self.redact(url.absoluteString), privacy: .public)")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch let e as URLError {
            switch e.code {
            case .timedOut: throw PanelLingoError.provider(provider, .timeout)
            case .cancelled: throw PanelLingoError.cancelled
            default: throw PanelLingoError.provider(provider, .unreachable(e.localizedDescription))
            }
        }
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw PanelLingoError.provider(provider, .unauthorized)
        case 404:
            let body = Self.errorMessage(data)
            if body.lowercased().contains("model") { throw PanelLingoError.provider(provider, .modelNotFound(body)) }
            throw PanelLingoError.provider(provider, .server(404, body))
        case 429:
            let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw PanelLingoError.provider(provider, .rateLimited(retryAfter: ra))
        default:
            throw PanelLingoError.provider(provider, .server(http.statusCode, Self.errorMessage(data)))
        }
    }

    public func json(_ method: String = "POST", url: URL, headers: [String: String] = [:], body: Any? = nil,
                     provider: ProviderKind) async throws -> [String: Any] {
        let data = try await send(method, url: url, headers: headers, json: body, provider: provider)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PanelLingoError.provider(provider, .malformedResponse("response is not a JSON object"))
        }
        return obj
    }

    /// Short human-readable error from a provider error body (never echoes request headers).
    static func errorMessage(_ data: Data) -> String {
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = o["error"] as? [String: Any], let m = e["message"] as? String { return redact(m) }
            if let m = o["error"] as? String { return redact(m) }
            if let m = o["message"] as? String { return redact(m) }
        }
        return redact(String(decoding: data.prefix(300), as: UTF8.self))
    }

    /// Removes anything that looks like a credential from log/error text.
    public static func redact(_ s: String) -> String {
        var out = s
        let patterns = [#"(?i)(key|token|auth[a-z]*)=([^&\s]+)"#, #"sk-[A-Za-z0-9_\-]{8,}"#, #"(?i)bearer\s+[A-Za-z0-9._\-]+"#,
                        #"AIza[0-9A-Za-z_\-]{20,}"#]
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "[REDACTED]", options: .regularExpression)
        }
        return out
    }

    public static func requireHTTPS(_ urlString: String, provider: ProviderKind) throws -> URL {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme?.lowercased(),
              url.host != nil else {
            throw PanelLingoError.provider(provider, .notConfigured("invalid endpoint URL"))
        }
        let local = provider.isLocal(baseURL: urlString)
        if scheme != "https" && !(scheme == "http" && local) {
            throw PanelLingoError.provider(provider, .notConfigured("remote endpoints must use HTTPS"))
        }
        return url
    }
}

/// API keys live only in the macOS Keychain (never in project files or logs).
public enum KeychainStore {
    static let service = "app.panellingo.providers"

    public static func set(_ secret: String?, for provider: ProviderKind) throws {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                     kSecAttrAccount: provider.rawValue]
        SecItemDelete(base as CFDictionary)
        guard let secret, !secret.isEmpty else { return }
        var add = base
        add[kSecValueData] = Data(secret.utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PanelLingoError.privacy("Keychain error \(status) while saving the \(provider.shortName) key")
        }
    }

    public static func get(_ provider: ProviderKind) -> String? {
        if let env = ProcessInfo.processInfo.environment["PANELLINGO_\(provider.rawValue.uppercased())_KEY"], !env.isEmpty { return env }
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                  kSecAttrAccount: provider.rawValue, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func has(_ provider: ProviderKind) -> Bool { get(provider) != nil }
}
