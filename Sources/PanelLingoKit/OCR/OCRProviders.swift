import CoreGraphics
import CoreImage
import Foundation
import NaturalLanguage
import Vision

public protocol OCRProvider: Sendable {
    var name: String { get }
    /// Languages this engine can actually recognise right now.
    func supportedLanguages() -> [String]
    func recognize(region: TextRegion, image: CGImage, language: String) async throws -> OCRResult
}

public enum TextJoiner {
    /// Joins OCR lines respecting the script: no spaces for CJK/Thai, de-hyphenation for others.
    public static func join(_ lines: [String], language: String?) -> String {
        let noSpaces = language.flatMap { LanguageInfo.info($0) }.map { !$0.usesSpaces } ?? lines.joined().containsCJK
        if noSpaces { return lines.joined() }
        var out = ""
        for l in lines.map({ $0.trimmingCharacters(in: .whitespaces) }) where !l.isEmpty {
            if out.isEmpty { out = l; continue }
            if out.hasSuffix("-"), let f = l.first, f.isLowercase { out.removeLast(); out += l } else { out += " " + l }
        }
        return out
    }

    public static func detectLanguage(_ text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let lang = r.dominantLanguage else { return nil }
        switch lang {
        case .simplifiedChinese: return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        default: return lang.rawValue
        }
    }
}

extension String {
    var containsCJK: Bool {
        unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    }
}

/// On-device OCR with Apple Vision plus comic-specific preprocessing.
public struct VisionOCRProvider: OCRProvider {
    public let name = "Apple Vision"
    public init() {}

    public func supportedLanguages() -> [String] { VisionLanguages.supported() }

    public func recognize(region: TextRegion, image: CGImage, language: String) async throws -> OCRResult {
        let mask = TextMaskBuilder.build(image: image, region: region)
        let canBeVertical = language == "auto" || (LanguageInfo.info(language)?.supportsVertical ?? false)
        var candidates: [OCRResult] = []
        func tryVertical() throws { if canBeVertical, let r = try recognizeVertical(mask: mask, image: image, language: language) { candidates.append(r) } }
        func tryHorizontal() throws { if let r = try recognizeHorizontal(region: region, mask: mask, image: image, language: language) { candidates.append(r) } }
        // Read in the detected orientation first; if that is weak, also try the other one and keep the better.
        if region.orientation == .vertical && canBeVertical { try tryVertical() } else { try tryHorizontal() }
        if (candidates.first?.confidence ?? 0) < 0.6 {
            if region.orientation == .vertical && canBeVertical { try tryHorizontal() } else { try tryVertical() }
        }
        func score(_ r: OCRResult) -> Double {
            var s = r.confidence * Double(min(r.text.count, 12) + 1)
            if r.orientation == region.orientation { s *= 1.15 }
            return s
        }
        var result = candidates.max { score($0) < score($1) }
            ?? OCRResult(text: "", confidence: 0, engine: name, language: nil, lines: [], orientation: region.orientation)
        if result.language == nil || language == "auto" { result.language = TextJoiner.detectLanguage(result.text) ?? (language == "auto" ? nil : language) }
        return result
    }

    /// Crops, cleans (white-out non-text) and upscales the region, then runs Vision.
    func recognizeHorizontal(region: TextRegion, mask: RegionMask, image: CGImage, language: String) throws -> OCRResult? {
        let rect = mask.rect
        var gray = GrayImage(image, crop: rect)
        // Suppress bubble borders / art outside the text mask to reduce OCR noise.
        if !mask.text.isEmpty {
            let keep = mask.text.dilated(max(2, Int(rect.height / 60)))
            for i in 0..<gray.pixels.count where keep.bits[i] == 0 { gray.pixels[i] = 255 }
        }
        let lineH = region.textLines.map { min($0.bbox.height, $0.bbox.width) }.max() ?? max(12, rect.height / 4)
        let up = lineH < 40 ? min(3, 48 / max(8, lineH)) : 1
        guard let cg = Self.prepare(gray, upscale: up) else { return nil }
        let lines = try Self.runVision(cg, language: language)
        guard !lines.isEmpty else { return nil }
        let sorted = lines.sorted { abs($0.rect.minY - $1.rect.minY) < $0.rect.height * 0.5 ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
        let mapped = sorted.map { l in
            TextLine(bbox: l.rect.scaled(by: 1 / up).offsetBy(dx: rect.x, dy: rect.y), text: l.text, confidence: l.confidence)
        }
        let conf = mapped.map(\.confidence).reduce(0, +) / Double(mapped.count)
        let lang = language == "auto" ? nil : language
        return OCRResult(text: TextJoiner.join(mapped.map(\.text), language: lang), confidence: conf, engine: "\(name)", language: lang,
                         lines: mapped, orientation: .horizontal)
    }

    /// Vertical CJK: slice columns (right→left) into glyph cells and re-lay them as horizontal lines.
    func recognizeVertical(mask: RegionMask, image: CGImage, language: String) throws -> OCRResult? {
        guard !mask.text.isEmpty else { return nil }
        let gray = GrayImage(image, crop: mask.rect)
        guard let reflow = VerticalReflow.reflow(gray: gray, text: mask.text), let cg = Self.prepare(reflow.image, upscale: 1) else { return nil }
        let lines = try Self.runVision(cg, language: language == "auto" ? "ja" : language)
        guard !lines.isEmpty else { return nil }
        // Map each recognised line back to its source column.
        var columnTexts = [String](repeating: "", count: reflow.columns.count)
        var confs: [Double] = []
        for l in lines.sorted(by: { $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }) {
            let idx = min(reflow.columns.count - 1, max(0, Int(l.rect.midY / reflow.lineHeight)))
            columnTexts[idx] += l.text.replacingOccurrences(of: " ", with: "")
            confs.append(l.confidence)
        }
        columnTexts = columnTexts.map(Self.normaliseVerticalPunctuation)
        let textLines = zip(reflow.columns, columnTexts).filter { !$0.1.isEmpty }.map { col, t in
            TextLine(bbox: col.offsetBy(dx: mask.rect.x, dy: mask.rect.y), text: t, confidence: confs.min() ?? 0)
        }
        let conf = confs.reduce(0, +) / Double(max(1, confs.count))
        let lang = language == "auto" ? nil : language
        return OCRResult(text: columnTexts.joined(), confidence: conf, engine: "\(name) (vertical)", language: lang,
                         lines: textLines, orientation: .vertical)
    }

    /// Vertical punctuation re-laid horizontally is often misread: ︙ → ：, column-final 。 → ・.
    static func normaliseVerticalPunctuation(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "：", with: "…").replacingOccurrences(of: "...", with: "…")
        if t.hasSuffix("・") { t.removeLast(); t += "。" }
        return t
    }

    /// Contrast stretch + optional upscale + white margin.
    static func prepare(_ g: GrayImage, upscale: Double) -> CGImage? {
        var g = g
        let lo = g.pixels.min() ?? 0, hi = g.pixels.max() ?? 255
        if hi > lo, hi - lo < 200 {
            let range = Double(hi - lo)
            g.pixels = g.pixels.map { UInt8(clamping: Int((Double($0 - lo) / range * 255).rounded())) }
        }
        guard let base = g.cgImage() else { return nil }
        let margin = 16.0
        let w = Int(Double(g.width) * upscale + margin * 2), h = Int(Double(g.height) * upscale + margin * 2)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: margin, y: margin, width: Double(g.width) * upscale, height: Double(g.height) * upscale))
        guard let out = ctx.makeImage() else { return nil }
        return out
    }

    /// Runs Vision; returned rects are relative to the un-margined, scaled crop.
    static func runVision(_ image: CGImage, language: String) throws -> [VisionLine] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        let langs = VisionLanguages.recognitionLanguages(for: language)
        if langs.isEmpty { req.automaticallyDetectsLanguage = true } else { req.recognitionLanguages = langs }
        req.usesLanguageCorrection = LanguageInfo.info(language)?.usesSpaces ?? true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        let full = PixelRect(x: 0, y: 0, width: Double(image.width), height: Double(image.height))
        return (req.results ?? []).compactMap { obs in
            // Choose the best of several candidates.
            guard let top = obs.topCandidates(3).max(by: { $0.confidence < $1.confidence }) else { return nil }
            let r = CoordinateConverter.pixelRect(fromVisionNormalized: obs.boundingBox, in: full).offsetBy(dx: -16, dy: -16)
            return VisionLine(rect: r, text: top.string, confidence: Double(top.confidence))
        }
    }
}

/// Re-lays vertical CJK columns as horizontal lines of upright glyphs so horizontal OCR can read them.
public enum VerticalReflow {
    public struct Result {
        public var image: GrayImage
        /// Column rects in crop coordinates, in reading order (right → left).
        public var columns: [PixelRect]
        public var lineHeight: Double
    }

    public static func reflow(gray: GrayImage, text: BitMask) -> Result? {
        guard let bb = text.boundingBox else { return nil }
        let estGlyph = max(6, bb.width / 6)
        var cols = BubbleDetector.projectionRuns(text, vertical: true, gapMin: max(2, Int(estGlyph * 0.12)))
        guard !cols.isEmpty else { return nil }
        let maxW = cols.map { $0.1 - $0.0 }.max() ?? 1
        // Drop furigana (ruby) columns: much narrower than the main columns.
        cols = cols.filter { Double($0.1 - $0.0) >= Double(maxW) * 0.5 }
        cols.reverse() // right → left
        let cw = Double(maxW)
        let lineH = cw * 1.6
        var lines: [[(x0: Int, x1: Int, y0: Int, y1: Int)]] = []
        var colRects: [PixelRect] = []
        for (x0, x1) in cols {
            // Row runs inside the column.
            let colMask = BitMask(width: x1 - x0, height: text.height, bits: (0..<text.height).flatMap { y in
                Array(text.bits[(y * text.width + x0)..<(y * text.width + x1)]) })
            let runs = BubbleDetector.projectionRuns(colMask, vertical: false, gapMin: 1)
            // Merge runs into roughly square glyph cells (handles multi-part glyphs like 二, 三, 小).
            var cells: [(Int, Int)] = []
            for r in runs {
                if let last = cells.last, Double(r.1 - last.0) <= cw * 1.12,
                   Double(last.1 - last.0) < cw * 0.8 || Double(r.1 - r.0) < cw * 0.45 {
                    cells[cells.count - 1] = (last.0, r.1)
                } else { cells.append(r) }
            }
            guard let first = cells.first, let last = cells.last else { continue }
            lines.append(cells.map { (x0, x1, $0.0, $0.1) })
            colRects.append(PixelRect(x: Double(x0), y: Double(first.0), width: Double(x1 - x0), height: Double(last.1 - first.0)))
        }
        guard !lines.isEmpty else { return nil }
        let gap = Int(cw * 0.18)
        let width = lines.map { l in l.reduce(0) { $0 + max($1.x1 - $1.x0, $1.y1 - $1.y0) + gap } }.max()! + gap * 2
        let height = Int(lineH * Double(lines.count))
        var out = GrayImage(width: max(8, width), height: max(8, height), fill: 255)
        for (li, cells) in lines.enumerated() {
            var cx = gap
            let baseY = Int(Double(li) * lineH + (lineH - cw) / 2)
            for c in cells {
                let w = c.x1 - c.x0, h = c.y1 - c.y0
                // Tall thin glyphs (ー, ｜, ︙) are vertical forms: rotate them to their horizontal form.
                let rotate = Double(h) > Double(w) * 2.2 && Double(h) > cw * 0.6
                let cellW = rotate ? h : w, cellH = rotate ? w : h
                let oy = baseY + Int((cw - Double(cellH)) / 2)
                for y in 0..<cellH {
                    for x in 0..<cellW {
                        let sx = rotate ? c.x0 + y : c.x0 + x
                        let sy = rotate ? c.y1 - 1 - x : c.y0 + y
                        let dx = cx + x, dy = oy + y
                        guard dx >= 0, dy >= 0, dx < out.width, dy < out.height, sx < gray.width, sy < gray.height else { continue }
                        if text[sx, sy] { out[dx, dy] = min(out[dx, dy], gray[sx, sy]) }
                    }
                }
                cx += cellW + gap
            }
        }
        return Result(image: out, columns: colRects, lineHeight: lineH)
    }
}
