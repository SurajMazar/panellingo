import Foundation

/// Detects comic panels by recursive X–Y cuts along blank gutters.
///
/// Works for the common grid / tiered layouts. Slanted or borderless panels fall back to a
/// single full-page panel, which is safe: reading order then relies on region geometry alone.
public struct PanelDetector: Sendable {
    /// Maximum fraction of "ink" pixels a row/column may contain to count as gutter.
    public var gutterInkFraction = 0.004
    public var inkThreshold: UInt8 = 200
    public var minPanelAreaFraction = 0.015

    public init() {}

    public func detect(_ gray: GrayImage, direction: ReadingDirection) -> [PixelRect] {
        let ink = gray.threshold(below: inkThreshold)
        // Integral counts of ink pixels per row/column inside a rect are computed on demand.
        let full = Box(x0: 0, y0: 0, x1: gray.width, y1: gray.height)
        let trimmed = trim(full, ink) ?? full
        var leaves: [Box] = []
        split(trimmed, ink: ink, horizontalFirst: true, depth: 0, direction: direction, into: &leaves)
        let minArea = Double(gray.width * gray.height) * minPanelAreaFraction
        let panels = leaves.compactMap { trim($0, ink) }.filter { Double($0.area) >= minArea }
        if panels.isEmpty { return [full.rect] }
        return panels.map(\.rect)
    }

    struct Box { var x0, y0, x1, y1: Int
        var w: Int { x1 - x0 }; var h: Int { y1 - y0 }; var area: Int { max(0, w) * max(0, h) }
        var rect: PixelRect { PixelRect(x: Double(x0), y: Double(y0), width: Double(w), height: Double(h)) }
    }

    private func rowInk(_ b: Box, _ ink: BitMask) -> [Int] {
        var out = [Int](repeating: 0, count: b.h)
        ink.bits.withUnsafeBufferPointer { bits in
            for y in b.y0..<b.y1 {
                var c = 0; let row = y * ink.width
                for x in b.x0..<b.x1 { c &+= Int(bits[row + x]) }
                out[y - b.y0] = c
            }
        }
        return out
    }

    private func colInk(_ b: Box, _ ink: BitMask) -> [Int] {
        var out = [Int](repeating: 0, count: b.w)
        ink.bits.withUnsafeBufferPointer { bits in
            for y in b.y0..<b.y1 {
                let row = y * ink.width
                for x in b.x0..<b.x1 { out[x - b.x0] &+= Int(bits[row + x]) }
            }
        }
        return out
    }

    /// Shrinks a box to the extent of its ink.
    private func trim(_ b: Box, _ ink: BitMask) -> Box? {
        guard b.w > 0, b.h > 0 else { return nil }
        let rows = rowInk(b, ink), cols = colInk(b, ink)
        let rLimit = max(1, Int(Double(b.w) * gutterInkFraction)), cLimit = max(1, Int(Double(b.h) * gutterInkFraction))
        guard let top = rows.firstIndex(where: { $0 > rLimit }), let bottom = rows.lastIndex(where: { $0 > rLimit }),
              let left = cols.firstIndex(where: { $0 > cLimit }), let right = cols.lastIndex(where: { $0 > cLimit }) else { return nil }
        return Box(x0: b.x0 + left, y0: b.y0 + top, x1: b.x0 + right + 1, y1: b.y0 + bottom + 1)
    }

    /// Finds gutter runs (start, end) in a projection.
    private func gutters(_ proj: [Int], span: Int, minRun: Int) -> [(Int, Int)] {
        let limit = max(1, Int(Double(span) * gutterInkFraction))
        var runs: [(Int, Int)] = []
        var start: Int?
        for (i, v) in proj.enumerated() {
            if v <= limit { if start == nil { start = i } } else if let s = start { if i - s >= minRun { runs.append((s, i)) }; start = nil }
        }
        return runs
    }

    private func split(_ b: Box, ink: BitMask, horizontalFirst: Bool, depth: Int, direction: ReadingDirection, into out: inout [Box]) {
        guard depth < 6, b.w > 8, b.h > 8 else { out.append(b); return }
        let minGutter = max(3, min(ink.width, ink.height) / 250)
        func cutRows() -> [Box]? {
            let g = gutters(rowInk(b, ink), span: b.w, minRun: minGutter).filter { $0.0 > 0 && $0.1 < b.h }
            guard !g.isEmpty else { return nil }
            var parts: [Box] = []; var y = 0
            for (s, e) in g { parts.append(Box(x0: b.x0, y0: b.y0 + y, x1: b.x1, y1: b.y0 + s)); y = e }
            parts.append(Box(x0: b.x0, y0: b.y0 + y, x1: b.x1, y1: b.y1))
            return parts.filter { $0.h > minGutter }
        }
        func cutCols() -> [Box]? {
            let g = gutters(colInk(b, ink), span: b.h, minRun: minGutter).filter { $0.0 > 0 && $0.1 < b.w }
            guard !g.isEmpty else { return nil }
            var parts: [Box] = []; var x = 0
            for (s, e) in g { parts.append(Box(x0: b.x0 + x, y0: b.y0, x1: b.x0 + s, y1: b.y1)); x = e }
            parts.append(Box(x0: b.x0 + x, y0: b.y0, x1: b.x1, y1: b.y1))
            let kept = parts.filter { $0.w > minGutter }
            return direction == .rightToLeft ? kept.reversed() : kept
        }
        let first = horizontalFirst ? cutRows() : cutCols()
        let second = first == nil ? (horizontalFirst ? cutCols() : cutRows()) : nil
        let usedHorizontal = first != nil ? horizontalFirst : !horizontalFirst
        guard let parts = first ?? second, parts.count > 1 else { out.append(b); return }
        for p in parts {
            guard let t = trim(p, ink) else { continue }
            split(t, ink: ink, horizontalFirst: !usedHorizontal, depth: depth + 1, direction: direction, into: &out)
        }
    }
}
