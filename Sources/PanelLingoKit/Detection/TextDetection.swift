import CoreGraphics
import Foundation

public struct DetectionOptions: Sendable {
    public var sourceLanguage: String
    public var readingDirection: ReadingDirection
    public var sensitivity: Double
    public var maxWorkingPixels: Int
    public var defaultStyle: TextStyle
    public init(sourceLanguage: String, readingDirection: ReadingDirection, sensitivity: Double = 0.5,
                maxWorkingPixels: Int = 40_000_000, defaultStyle: TextStyle = TextStylePresets.classic) {
        self.sourceLanguage = sourceLanguage; self.readingDirection = readingDirection; self.sensitivity = sensitivity
        self.maxWorkingPixels = maxWorkingPixels; self.defaultStyle = defaultStyle
    }
}

public struct DetectionOutput: Sendable {
    public var panels: [ComicPanel]
    public var regions: [TextRegion]
    public var workingScale: Double
}

public protocol TextDetectionProvider: Sendable {
    var name: String { get }
    func detect(image: CGImage, options: DetectionOptions) async throws -> DetectionOutput
}

/// Hybrid detector: Vision text lines + classical bubble/box analysis + panel X–Y cuts, merged
/// and ordered. All results are mapped back to source-image pixel coordinates.
public struct HybridTextDetector: TextDetectionProvider {
    public let name = "hybrid-vision-bubble"
    public init() {}

    public func detect(image: CGImage, options: DetectionOptions) async throws -> DetectionOutput {
        let w = Double(image.width), h = Double(image.height)
        let scale = min(1.0, (Double(options.maxWorkingPixels) / (w * h)).squareRoot())
        let gray = GrayImage(image, scale: scale)
        try Task.checkCancellation()

        let panelRects = PanelDetector().detect(gray, direction: options.readingDirection)
        let panels = panelRects.enumerated().map { ComicPanel(bbox: CoordinateConverter.toSource($1, workingScale: scale), index: $0) }
        try Task.checkCancellation()

        var bubbleDetector = BubbleDetector(sensitivity: options.sensitivity)
        bubbleDetector.whiteThreshold = UInt8(clamping: Int(205 - options.sensitivity * 20))
        let bubbles = bubbleDetector.detect(gray)
        try Task.checkCancellation()

        let lines = (try? VisionTextDetector().detect(image, sourceLanguage: options.sourceLanguage)) ?? []
        try Task.checkCancellation()

        let regions = RegionAssembler.assemble(bubbles: bubbles, lines: lines, scale: scale, pageWidth: w, pageHeight: h,
                                               options: options)
        let ordered = ReadingOrder.order(regions, panels: panels, direction: options.readingDirection)
        return DetectionOutput(panels: panels, regions: ordered, workingScale: scale)
    }
}

public enum RegionAssembler {
    public static func assemble(bubbles: [BubbleCandidate], lines: [VisionLine], scale: Double,
                                pageWidth: Double, pageHeight: Double, options: DetectionOptions) -> [TextRegion] {
        var regions: [TextRegion] = []
        var used = [Bool](repeating: false, count: lines.count)
        let cjk = ["ja", "zh-Hans", "zh-Hant", "ko"].contains(options.sourceLanguage)

        for b in bubbles {
            let rect = CoordinateConverter.toSource(b.rect, workingScale: scale)
            var inside: [TextLine] = []
            for (i, l) in lines.enumerated() where !used[i] {
                let c = l.rect.center
                let wc = PixelPoint(x: c.x * scale - b.rect.x, y: c.y * scale - b.rect.y)
                let inShape = wc.x >= 0 && wc.y >= 0 && Int(wc.x) < b.shape.width && Int(wc.y) < b.shape.height
                    && b.shape[Int(wc.x), Int(wc.y)]
                if inShape || l.rect.coverage(by: rect) > 0.7 {
                    used[i] = true
                    inside.append(TextLine(bbox: l.rect, text: l.text, confidence: l.confidence))
                }
            }
            var orientation = b.orientation
            if !inside.isEmpty {
                let horizontalLines = inside.filter { $0.bbox.width > $0.bbox.height * 1.2 }.count
                if horizontalLines * 2 >= inside.count && !(cjk && b.orientation == .vertical && inside.allSatisfy { $0.text.count <= 2 }) {
                    orientation = .horizontal
                }
            }
            if !cjk { orientation = .horizontal }
            // Without any Vision support, a lone low-score candidate is probably artwork.
            if inside.isEmpty && b.score < 0.62 && !(cjk && orientation == .vertical) { continue }
            let contour = b.shape.outerContour().map {
                PixelPoint(x: ($0.x + b.rect.x) / scale, y: ($0.y + b.rect.y) / scale)
            }
            let poly = PolygonMath.simplify(contour, tolerance: max(1.5, rect.width / 120))
            let kind: RegionKind = b.isRectangular ? .caption : .speech
            var r = TextRegion(kind: kind, bbox: rect, polygon: poly.count >= 3 ? poly : nil, textLines: inside,
                               confidence: min(1, b.score + (inside.isEmpty ? 0 : 0.2)), orientation: orientation,
                               detector: "bubble", style: TextStylePresets.style(for: kind, projectDefault: options.defaultStyle))
            r.detectedLanguage = options.sourceLanguage == "auto" ? nil : options.sourceLanguage
            regions.append(r)
        }

        // Remaining Vision lines → free-floating text blocks.
        let rest = lines.enumerated().filter { !used[$0.offset] }.map(\.element).filter { l in
            let stripped = l.text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces).union(.symbols))
            return !(stripped.isEmpty || (stripped.count == 1 && l.confidence < 0.5))
        }
        let allHeights = lines.map { min($0.rect.height, $0.rect.width) }.sorted()
        let medianH = allHeights.isEmpty ? 0 : allHeights[allHeights.count / 2]
        for block in groupLines(rest) {
            let bbox = block.reduce(PixelRect.zero) { $0.union($1.rect) }
            let lineH = block.map { min($0.rect.height, $0.rect.width) }.max() ?? 0
            let isSFX = lineH > max(pageHeight * 0.035, medianH * 2.2) && block.count <= 2
            let kind: RegionKind = isSFX ? .sfx : .freeText
            let pad = lineH * 0.2
            let rect = bbox.insetBy(dx: -pad, dy: -pad).clamped(width: pageWidth, height: pageHeight)
            let conf = block.map(\.confidence).reduce(0, +) / Double(block.count)
            let vertical = cjk && block.allSatisfy { $0.rect.height > $0.rect.width * 1.5 }
            var r = TextRegion(kind: kind, bbox: rect, textLines: block.map { TextLine(bbox: $0.rect, text: $0.text, confidence: $0.confidence) },
                               confidence: conf, orientation: vertical ? .vertical : .horizontal, detector: "vision",
                               style: TextStylePresets.style(for: kind, projectDefault: options.defaultStyle))
            r.detectedLanguage = options.sourceLanguage == "auto" ? nil : options.sourceLanguage
            regions.append(r)
        }
        return dedupe(regions)
    }

    /// Groups Vision lines into paragraphs by proximity, overlap and similar size.
    public static func groupLines(_ lines: [VisionLine]) -> [[VisionLine]] {
        var parent = Array(lines.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in lines.indices {
            for j in lines.indices where j > i {
                let a = lines[i].rect, b = lines[j].rect
                let ha = min(a.height, a.width), hb = min(b.height, b.width)
                guard max(ha, hb) / max(1, min(ha, hb)) < 1.9 else { continue }
                let lineH = max(ha, hb)
                let vGap = max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))
                let hGap = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
                let hOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                let vOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                let stacked = vGap < lineH * 1.1 && hOverlap > min(a.width, b.width) * 0.25
                let sideBySide = hGap < lineH * 1.1 && vOverlap > min(a.height, b.height) * 0.25
                if stacked || sideBySide { parent[find(j)] = find(i) }
            }
        }
        var groups: [Int: [VisionLine]] = [:]
        for i in lines.indices { groups[find(i), default: []].append(lines[i]) }
        return groups.values.map { $0.sorted { $0.rect.minY < $1.rect.minY } }.sorted { $0[0].rect.minY < $1[0].rect.minY }
    }

    /// Drops regions largely contained in another region of equal or higher confidence.
    public static func dedupe(_ regions: [TextRegion], threshold: Double = 0.7) -> [TextRegion] {
        var keep = [Bool](repeating: true, count: regions.count)
        for i in regions.indices where keep[i] {
            for j in regions.indices where j != i && keep[j] && keep[i] {
                let a = regions[i], b = regions[j]
                if a.bbox.iou(b.bbox) > threshold || a.bbox.coverage(by: b.bbox) > 0.85 {
                    // Keep the enclosing bubble over an inner Vision block.
                    if b.kind.isEnclosed && !a.kind.isEnclosed { keep[i] = false }
                    else if a.kind.isEnclosed && !b.kind.isEnclosed { keep[j] = false }
                    else if a.bbox.area < b.bbox.area { keep[i] = false } else { keep[j] = false }
                }
            }
        }
        return zip(regions, keep).filter(\.1).map(\.0)
    }

    /// Merges regions into one (user command).
    public static func merge(_ regions: [TextRegion]) -> TextRegion? {
        guard var first = regions.sorted(by: { $0.readingIndex < $1.readingIndex }).first else { return nil }
        let rest = regions.filter { $0.id != first.id }.sorted { $0.readingIndex < $1.readingIndex }
        for r in rest {
            first.bbox = first.bbox.union(r.bbox)
            first.textLines += r.textLines
            if let o = r.ocr {
                if var fo = first.ocr { fo.text += (fo.text.isEmpty ? "" : "\n") + o.text; fo.lines += o.lines; first.ocr = fo } else { first.ocr = o }
            }
            if let c = r.correctedText { first.correctedText = (first.correctedText ?? first.ocr?.text ?? "") + "\n" + c }
        }
        first.polygon = nil
        first.translation = nil
        first.translationLocked = false
        first.cleanup = CleanupState()
        return first
    }

    /// Splits a region into two along its longer axis, distributing its text lines.
    public static func split(_ r: TextRegion) -> [TextRegion] {
        let vertical = r.bbox.width >= r.bbox.height
        var a = r, b = r
        a.id = TextRegion.makeID(); b.id = TextRegion.makeID()
        if vertical {
            let mid = r.bbox.midX
            a.bbox = PixelRect(x: r.bbox.x, y: r.bbox.y, width: r.bbox.width / 2, height: r.bbox.height)
            b.bbox = PixelRect(x: mid, y: r.bbox.y, width: r.bbox.width / 2, height: r.bbox.height)
            a.textLines = r.textLines.filter { $0.bbox.midX < mid }; b.textLines = r.textLines.filter { $0.bbox.midX >= mid }
        } else {
            let mid = r.bbox.midY
            a.bbox = PixelRect(x: r.bbox.x, y: r.bbox.y, width: r.bbox.width, height: r.bbox.height / 2)
            b.bbox = PixelRect(x: r.bbox.x, y: mid, width: r.bbox.width, height: r.bbox.height / 2)
            a.textLines = r.textLines.filter { $0.bbox.midY < mid }; b.textLines = r.textLines.filter { $0.bbox.midY >= mid }
        }
        for i in [0, 1] {
            var x = i == 0 ? a : b
            x.polygon = nil; x.ocr = nil; x.correctedText = nil; x.translation = nil; x.translationLocked = false
            x.cleanup = CleanupState(); x.isManual = true
            x.readingIndex = r.readingIndex + i
            if i == 0 { a = x } else { b = x }
        }
        return [a, b]
    }
}
