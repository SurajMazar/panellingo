import CryptoKit
import Foundation
import os

public enum PanelLingoError: LocalizedError, Sendable {
    case unsupportedFile(String)
    case corruptFile(String)
    case imageDecodeFailed(String)
    case projectFormat(String)
    case stage(PipelineStage, String)
    case provider(ProviderKind, ProviderFailure)
    case privacy(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let s): "Unsupported file: \(s)"
        case .corruptFile(let s): "The file appears to be damaged: \(s)"
        case .imageDecodeFailed(let s): "Could not decode image: \(s)"
        case .projectFormat(let s): "Project could not be read: \(s)"
        case .stage(let st, let s): "\(st.displayName) failed: \(s)"
        case .provider(let k, let f): "\(k.shortName): \(f.message)"
        case .privacy(let s): s
        case .cancelled: "Cancelled"
        }
    }
}

public enum ProviderFailure: Sendable, Equatable {
    case notConfigured(String)
    case unreachable(String)
    case unauthorized
    case rateLimited(retryAfter: Double?)
    case timeout
    case server(Int, String)
    case malformedResponse(String)
    case unsupportedLanguagePair(String, String)
    case languageNotInstalled(String, String)
    case modelNotFound(String)

    public var message: String {
        switch self {
        case .notConfigured(let s): "Not configured — \(s)"
        case .unreachable(let s): "Cannot connect (\(s)). Is the service running?"
        case .unauthorized: "The API key was rejected (401/403). Check the key in Settings › AI Providers."
        case .rateLimited(let r): "Rate limited by the provider" + (r.map { ", retry after \(Int($0)) s" } ?? "") + "."
        case .timeout: "The request timed out."
        case .server(let c, let s): "Server error \(c): \(s)"
        case .malformedResponse(let s): "The model returned an unusable response: \(s)"
        case .unsupportedLanguagePair(let a, let b): "\(LanguageInfo.name(a)) → \(LanguageInfo.name(b)) is not supported by this provider."
        case .languageNotInstalled(let a, let b): "Language pack for \(LanguageInfo.name(a)) → \(LanguageInfo.name(b)) is not downloaded. Open System Settings › General › Language & Region › Translation Languages to download it."
        case .modelNotFound(let m): "Model “\(m)” is not available on this provider."
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .timeout, .malformedResponse, .unreachable: true
        case .server(let c, _): c >= 500
        default: false
        }
    }
}

public enum Log {
    public static let pipeline = Logger(subsystem: "app.panellingo", category: "pipeline")
    public static let network = Logger(subsystem: "app.panellingo", category: "network")
    public static let storage = Logger(subsystem: "app.panellingo", category: "storage")
}

public enum NaturalSort {
    /// Finder-style ordering: "2" < "10".
    public static func less(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    public static func sorted<T>(_ items: [T], by key: (T) -> String) -> [T] {
        items.sorted { less(key($0), key($1)) }
    }
}

public enum Hashing {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum FileIO {
    /// Writes `data` atomically (temp file + rename) creating parent directories.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Removes characters that are illegal or dangerous in file names while keeping Unicode.
    public static func sanitizeFileName(_ name: String, fallback: String = "untitled") -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\0").union(.controlCharacters).union(.newlines)
        var s = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 180 { s = String(s.prefix(180)) }
        return s.isEmpty ? fallback : s
    }
}

/// Lightweight cancellation-aware async semaphore used to bound expensive work.
public actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) { available = max(1, limit) }

    public func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }

    public func run<T>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await work()
    }
}

/// Requests-per-minute limiter for API usage limits.
public actor RateLimiter {
    private var stamps: [Date] = []
    public init() {}
    public func wait(perMinute: Int) async throws {
        guard perMinute > 0 else { return }
        while true {
            let now = Date()
            stamps.removeAll { now.timeIntervalSince($0) > 60 }
            if stamps.count < perMinute { stamps.append(now); return }
            let wait = 60 - now.timeIntervalSince(stamps[0]) + 0.05
            try await Task.sleep(nanoseconds: UInt64(max(0.05, wait) * 1_000_000_000))
        }
    }
}
