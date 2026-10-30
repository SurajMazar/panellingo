import Foundation

/// A bright enclosed shape (speech bubble, caption box) containing glyph-like dark components.
public struct BubbleCandidate: Sendable {
    /// Bounding box in working-image pixels.
    public var rect: PixelRect
    /// Bubble interior incl. text (cropped to `rect`).
    public var shape: BitMask
    /// Text pixels inside the bubble (cropped to `rect`).
    public var text: BitMask
    public var textRect: PixelRect
    public var fillRatio: Double
    public var glyphCount: Int
    public var medianGlyphHeight: Double
    public var orientation: TextOrientation
    public var score: Double
    public var isRectangular: Bool { fillRatio > 0.9 }
}

/// Classical speech-bubble detector: bright connected regions whose holes look like lettering.
public struct BubbleDetector: Sendable {
    public var whiteThreshold: UInt8 = 200
    public var minAreaFraction = 0.0006
    public var maxAreaFraction = 0.35
    /// 0…1; higher finds more (and noisier) candidates.
    public var sensitivity = 0.5

    public init(sensitivity: Double = 0.5) { self.sensitivity = sensitivity }

    public func detect(_ gray: GrayImage) -> [BubbleCandidate] {
        let white = gray.threshold(atLeast: whiteThreshold)
        let labels = ComponentLabels(white)
        let pageArea = Double(gray.width * gray.height)
        var out: [BubbleCandidate] = []
        for c in labels.components {
            let bboxArea = Double(c.width * c.height)
            guard Double(c.area) >= pageArea * minAreaFraction, bboxArea <= pageArea * maxAreaFraction,
                  c.width >= 16, c.height >= 16 else { continue }
            // Components spanning the page edge are usually gutters/background.
            if c.touchesBorder && (bboxArea > pageArea * 0.08 || c.fillRatio < 0.5) { continue }
            let (comp, ox, oy) = labels.mask(of: c)
            guard let cand = analyse(comp: comp, originX: ox, originY: oy, gray: gray) else { continue }
            out.append(cand)
        }
        return dedupe(out)
    }

    /// Examines one bright component: fills holes, extracts glyph-like holes, scores textness.
    func analyse(comp: BitMask, originX: Int, originY: Int, gray: GrayImage) -> BubbleCandidate? {
        let filled = comp.filledHoles()
        let filledArea = filled.count
        let fill = Double(filledArea) / Double(comp.width * comp.height)
        guard fill >= 0.42 else { return nil }
        var holes = filled
        for i in 0..<holes.bits.count where comp.bits[i] != 0 { holes.bits[i] = 0 }
        let holeArea = holes.count
        let holeRatio = Double(holeArea) / Double(filledArea)
        guard holeArea > 0, holeRatio >= 0.004, holeRatio <= 0.55 else { return nil }

        // Glyph analysis on hole components (8-connected so strokes of one glyph stay together).
        let hl = ComponentLabels(holes, eightConnected: true)
        let glyphs = hl.components.filter { $0.area >= 4 }
        guard !glyphs.isEmpty else { return nil }
        let heights = glyphs.map { Double($0.height) }.sorted()
        let median = heights[heights.count / 2]
        guard median >= 5, median <= Double(comp.height) * 0.6 else { return nil }
        let consistent = glyphs.filter { Double($0.height) >= median * 0.25 && Double($0.height) <= median * 2.6 }.count
        let consistency = Double(consistent) / Double(glyphs.count)
        // Dark enough to be lettering?
        var darkSum = 0, darkN = 0
        for y in 0..<holes.height {
            for x in 0..<holes.width where holes[x, y] {
                darkSum += Int(gray[originX + x, originY + y]); darkN += 1
            }
        }
        let meanDark = Double(darkSum) / Double(max(1, darkN))
        let minGlyphs = sensitivity > 0.7 ? 1 : 2
        guard glyphs.count >= minGlyphs, consistency >= 0.45 - sensitivity * 0.2, meanDark < 150 else { return nil }
        // Text should sit inside the bubble, not hug the border (art overlapping a white area).
        guard let tb = holes.boundingBox else { return nil }
        let marginX = min(tb.minX, Double(comp.width) - tb.maxX) / Double(comp.width)
        let marginY = min(tb.minY, Double(comp.height) - tb.maxY) / Double(comp.height)
        guard marginX > 0.01 || marginY > 0.01 else { return nil }

        let orientation = Self.orientation(of: holes, glyphHeight: median)
        Log.pipeline.debug("bubble@\(originX),\(originY) \(comp.width)x\(comp.height) glyphs=\(glyphs.count) median=\(median) consistency=\(consistency) dark=\(meanDark)")
        var score = 0.35 + 0.25 * consistency + 0.15 * min(1, Double(glyphs.count) / 6)
        score += 0.15 * min(1, max(0, (150 - meanDark) / 100))
        score += fill > 0.6 ? 0.1 : 0
        let rect = PixelRect(x: Double(originX), y: Double(originY), width: Double(comp.width), height: Double(comp.height))
        return BubbleCandidate(rect: rect, shape: filled, text: holes, textRect: tb.offsetBy(dx: Double(originX), dy: Double(originY)),
                               fillRatio: fill, glyphCount: glyphs.count, medianGlyphHeight: median,
                               orientation: orientation, score: min(1, score))
    }

    /// Vertical when column runs are much more elongated than row runs.
    public static func orientation(of text: BitMask, glyphHeight: Double) -> TextOrientation {
        guard let bb = text.boundingBox else { return .horizontal }
        let cols = projectionRuns(text, vertical: true, gapMin: 2)
        let rows = projectionRuns(text, vertical: false, gapMin: 2)
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 1 : s[s.count / 2] }
        // Column runs span the full text height; row runs span the full text width.
        let vScore = bb.height / max(1, median(cols.map { Double($0.1 - $0.0) }))
        let hScore = bb.width / max(1, median(rows.map { Double($0.1 - $0.0) }))
        return vScore > hScore * 1.1 && bb.height > glyphHeight * 1.6 ? .vertical : .horizontal
    }

    /// Runs of non-empty columns (vertical = true) or rows separated by gaps ≥ gapMin.
    public static func projectionRuns(_ m: BitMask, vertical: Bool, gapMin: Int) -> [(Int, Int)] {
        let n = vertical ? m.width : m.height
        var proj = [Int](repeating: 0, count: n)
        for y in 0..<m.height { for x in 0..<m.width where m.bits[y * m.width + x] != 0 { proj[vertical ? x : y] += 1 } }
        var runs: [(Int, Int)] = []
        var start: Int?, gap = 0
        for i in 0..<n {
            if proj[i] > 0 {
                if start == nil { start = i }
                gap = 0
            } else if let s = start {
                gap += 1
                if gap >= gapMin { runs.append((s, i - gap + 1)); start = nil; gap = 0 }
            }
        }
        if let s = start { runs.append((s, n - gap)) }
        return runs
    }

    /// Removes nested duplicates: when one candidate sits inside another, keep the higher scoring.
    func dedupe(_ c: [BubbleCandidate]) -> [BubbleCandidate] {
        var keep = [Bool](repeating: true, count: c.count)
        for i in 0..<c.count where keep[i] {
            for j in (i + 1)..<max(i + 1, c.count) where keep[j] {
                let a = c[i].rect, b = c[j].rect
                if a.iou(b) > 0.6 || a.coverage(by: b) > 0.85 || b.coverage(by: a) > 0.85 {
                    // Prefer the outer bubble when text overlaps (inner white = letter counters).
                    let ta = c[i].textRect, tb = c[j].textRect
                    if ta.coverage(by: tb) > 0.6 || tb.coverage(by: ta) > 0.6 {
                        if a.area >= b.area { keep[j] = false } else { keep[i] = false }
                    } else if c[i].score >= c[j].score { keep[j] = false } else { keep[i] = false }
                }
            }
        }
        return zip(c, keep).filter(\.1).map(\.0)
    }
}
