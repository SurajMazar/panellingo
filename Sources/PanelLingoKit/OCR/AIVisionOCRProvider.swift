import CoreGraphics
import Foundation

/// OCR through a vision-capable language model (e.g. a local Ollama `qwen3-vl` model).
///
/// Useful for handwritten lettering, stylised fonts and scripts Apple Vision does not read.
/// Respects privacy settings: remote providers are only used when images may be sent.
public struct AIVisionOCRProvider: OCRProvider {
    public let configuration: ProviderConfiguration
    public let privacy: PrivacySettings
    public var name: String { "AI Vision (\(configuration.kind.shortName) \(configuration.model))" }

    public init(configuration: ProviderConfiguration, privacy: PrivacySettings) {
        self.configuration = configuration; self.privacy = privacy
    }

    public func supportedLanguages() -> [String] { LanguageInfo.all.map(\.code) }

    public func recognize(region: TextRegion, image: CGImage, language: String) async throws -> OCRResult {
        guard configuration.kind.supportsVision else {
            throw PanelLingoError.stage(.ocr, "\(configuration.kind.shortName) cannot read images; choose a vision-capable provider")
        }
        if !configuration.isLocal {
            if privacy.localOnly || !privacy.allowSendingImages {
                throw PanelLingoError.privacy("AI Vision OCR would send image crops to \(configuration.kind.shortName); allow sending images in Settings › Privacy or use a local model.")
            }
        }
        let pad = max(6, min(region.bbox.width, region.bbox.height) * 0.06)
        let rect = region.bbox.insetBy(dx: -pad, dy: -pad).integral.clamped(width: Double(image.width), height: Double(image.height))
        guard let crop = image.cropping(to: rect.cgRect) else { throw PanelLingoError.stage(.ocr, "empty crop") }
        // Keep requests small: long side ≤ 1024 px, upscale tiny crops.
        let longSide = Double(max(crop.width, crop.height))
        let scale = longSide > 1024 ? 1024 / longSide : (longSide < 256 ? 2 : 1)
        guard let jpeg = Self.jpeg(crop, scale: scale) else { throw PanelLingoError.stage(.ocr, "could not encode crop") }
        let langName = language == "auto" ? "the original language" : LanguageInfo.name(language)
        let dir = region.orientation == .vertical ? " The text is written vertically in columns read right to left." : ""
        let call = ChatCall(
            system: "You are a precise OCR engine for comics. Transcribe lettering exactly; never translate or explain.",
            user: "Transcribe all text in this comic speech-bubble crop, written in \(langName).\(dir) Output only the text, with a line break between separate lines. If there is no text, output nothing.",
            imageJPEG: jpeg, jsonSchema: false)
        let raw = try await LLMTranslationProvider(configuration: configuration).complete(call)
        var text = raw
        if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]) }
        text = text.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let lang = language == "auto" ? TextJoiner.detectLanguage(text) : language
        return OCRResult(text: TextJoiner.join(lines, language: lang), confidence: text.isEmpty ? 0 : 0.7, engine: name,
                         language: lang, lines: [TextLine(bbox: rect, text: text, confidence: 0.7)])
    }

    static func jpeg(_ img: CGImage, scale: Double) -> Data? {
        let w = max(1, Int(Double(img.width) * scale)), h = max(1, Int(Double(img.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: RGBAImage.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage().flatMap { try? ImageIOHelper.encode($0, type: .jpeg, quality: 0.9) }
    }
}
