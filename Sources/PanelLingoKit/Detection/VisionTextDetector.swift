import CoreGraphics
import Foundation
import Vision

/// A text line observed by Apple Vision, in full-image pixel coordinates.
public struct VisionLine: Sendable {
    public var rect: PixelRect
    public var text: String
    public var confidence: Double
}

public enum VisionLanguages {
    /// Languages the installed Vision revision can recognise (queried at runtime, never assumed).
    public static func supported() -> [String] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        return (try? req.supportedRecognitionLanguages()) ?? []
    }

    /// Vision language identifiers for a project source language.
    public static func recognitionLanguages(for source: String) -> [String] {
        let supported = Set(supported())
        var langs: [String] = []
        if source != "auto", let v = LanguageInfo.info(source)?.visionCode, supported.contains(v) { langs.append(v) }
        if source.hasPrefix("zh"), supported.contains("zh-Hans"), supported.contains("zh-Hant") {
            langs = source == "zh-Hant" ? ["zh-Hant", "zh-Hans"] : ["zh-Hans", "zh-Hant"]
        }
        if langs.isEmpty == false, !["en-US"].contains(langs[0]), supported.contains("en-US") { langs.append("en-US") }
        return langs
    }

    public static func isSupported(_ source: String) -> Bool {
        source == "auto" || !recognitionLanguages(for: source).isEmpty
    }
}

/// Runs Vision text recognition over a full page, tiling very tall (webtoon) images.
public struct VisionTextDetector: Sendable {
    public var minimumTextHeightFraction: Float = 0.006
    public init() {}

    public func detect(_ image: CGImage, sourceLanguage: String) throws -> [VisionLine] {
        let w = Double(image.width), h = Double(image.height)
        let tileH = max(w * 2.0, 1600)
        if h <= tileH * 1.2 {
            return try recognize(image, region: PixelRect(x: 0, y: 0, width: w, height: h), language: sourceLanguage)
        }
        var lines: [VisionLine] = []
        var y = 0.0
        let overlap = tileH * 0.12
        while y < h {
            let r = PixelRect(x: 0, y: y, width: w, height: min(tileH, h - y))
            if let tile = image.cropping(to: r.cgRect) {
                for l in try recognize(tile, region: r, language: sourceLanguage)
                where !lines.contains(where: { $0.rect.iou(l.rect) > 0.5 }) {
                    lines.append(l)
                }
            }
            if r.maxY >= h { break }
            y += tileH - overlap
        }
        return lines
    }

    func recognize(_ image: CGImage, region: PixelRect, language: String) throws -> [VisionLine] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.minimumTextHeight = minimumTextHeightFraction
        let langs = VisionLanguages.recognitionLanguages(for: language)
        if langs.isEmpty { req.automaticallyDetectsLanguage = true } else { req.recognitionLanguages = langs }
        req.usesLanguageCorrection = LanguageInfo.info(language)?.usesSpaces ?? true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([req])
        let region0 = PixelRect(x: 0, y: 0, width: region.width, height: region.height)
        return (req.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            let r = CoordinateConverter.pixelRect(fromVisionNormalized: obs.boundingBox, in: region0)
                .offsetBy(dx: region.x, dy: region.y)
            return VisionLine(rect: r, text: top.string, confidence: Double(top.confidence))
        }
    }
}
