import CoreGraphics
import Foundation

/// Lettering mask for one region, at full source resolution.
public struct RegionMask: Sendable {
    /// Source-pixel rect the bitmaps cover.
    public var rect: PixelRect
    /// Lettering pixels (1 = text).
    public var text: BitMask
    /// Bubble interior incl. text when the region is an enclosed bubble; nil otherwise.
    public var shape: BitMask?
    /// Estimated background (paper) gray level.
    public var background: UInt8
    public var method: String
}

/// Builds tight lettering masks so cleanup touches only text pixels, never bubble borders.
public enum TextMaskBuilder {
    public static func build(image: CGImage, region: TextRegion, whiteThreshold: UInt8 = 200) -> RegionMask {
        let pad = max(4, min(region.bbox.width, region.bbox.height) * 0.04)
        let rect = region.bbox.insetBy(dx: -pad, dy: -pad).integral
            .clamped(width: Double(image.width), height: Double(image.height))
        let gray = GrayImage(image, crop: rect)
        if region.kind.isEnclosed, let m = bubbleMask(gray, rect: rect, region: region, whiteThreshold: whiteThreshold) {
            return m
        }
        return contrastMask(gray, rect: rect, region: region)
    }

    /// Finds the bubble interior component inside the crop and returns its holes as text.
    static func bubbleMask(_ gray: GrayImage, rect: PixelRect, region: TextRegion, whiteThreshold: UInt8) -> RegionMask? {
        let white = gray.threshold(atLeast: whiteThreshold)
        let labels = ComponentLabels(white)
        let target = region.bbox.offsetBy(dx: -rect.x, dy: -rect.y)
        let best = labels.components
            .filter { !$0.touchesBorder && $0.rect.coverage(by: target) > 0.6 && $0.rect.area > target.area * 0.35 }
            .max { $0.area < $1.area }
        guard let c = best else { return nil }
        // Rebuild the component mask in full-crop coordinates.
        var comp = BitMask(width: gray.width, height: gray.height)
        for i in 0..<labels.labels.count where labels.labels[i] == c.label { comp.bits[i] = 1 }
        let shape = comp.filledHoles()
        var text = shape
        for i in 0..<text.bits.count where comp.bits[i] != 0 { text.bits[i] = 0 }
        guard !text.isEmpty else { return nil }
        // Paper tone = median of interior non-text pixels.
        var hist = [Int](repeating: 0, count: 256)
        for i in 0..<comp.bits.count where comp.bits[i] != 0 { hist[Int(gray.pixels[i])] += 1 }
        return RegionMask(rect: rect, text: text, shape: shape, background: median(hist), method: "bubble")
    }

    /// Generic mask: pixels contrasting with the estimated local background, excluding components that
    /// cross the crop edge (bubble borders, panel lines, artwork).
    static func contrastMask(_ gray: GrayImage, rect: PixelRect, region: TextRegion) -> RegionMask {
        var hist = [Int](repeating: 0, count: 256)
        let w = gray.width, h = gray.height
        for x in 0..<w { hist[Int(gray[x, 0])] += 1; hist[Int(gray[x, h - 1])] += 1 }
        for y in 0..<h { hist[Int(gray[0, y])] += 1; hist[Int(gray[w - 1, y])] += 1 }
        let bg = median(hist)
        let delta = 60
        var cand = BitMask(width: w, height: h)
        for i in 0..<gray.pixels.count where abs(Int(gray.pixels[i]) - Int(bg)) > delta { cand.bits[i] = 1 }
        // Limit to text line boxes when known (keeps artwork outside lettering intact).
        var allowed: BitMask? = nil
        if !region.textLines.isEmpty {
            var a = BitMask(width: w, height: h)
            for l in region.textLines {
                let lr = l.bbox.insetBy(dx: -l.bbox.height * 0.25, dy: -l.bbox.height * 0.2)
                    .offsetBy(dx: -rect.x, dy: -rect.y).integral.clamped(width: Double(w), height: Double(h))
                if lr.isEmpty { continue }
                for y in Int(lr.minY)..<Int(lr.maxY) { for x in Int(lr.minX)..<Int(lr.maxX) { a.bits[y * w + x] = 1 } }
            }
            if !a.isEmpty { allowed = a }
        }
        let labels = ComponentLabels(cand, eightConnected: true)
        var text = BitMask(width: w, height: h)
        let maxArea = Double(w * h) * 0.4
        for c in labels.components where !c.touchesBorder && Double(c.area) < maxArea {
            for y in c.minY...c.maxY {
                for x in c.minX...c.maxX where labels.labels[y * w + x] == c.label {
                    if allowed?[x, y] ?? true { text.bits[y * w + x] = 1 }
                }
            }
        }
        return RegionMask(rect: rect, text: text, shape: nil, background: bg, method: "contrast")
    }

    static func median(_ hist: [Int]) -> UInt8 {
        let total = hist.reduce(0, +)
        var acc = 0
        for (i, c) in hist.enumerated() { acc += c; if acc * 2 >= total { return UInt8(i) } }
        return 255
    }
}
