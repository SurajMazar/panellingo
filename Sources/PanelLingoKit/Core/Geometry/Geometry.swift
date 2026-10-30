import CoreGraphics
import Foundation

/// A point in source-image pixel space (origin top-left, y grows downward).
public struct PixelPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// A rectangle in source-image pixel space (origin top-left, y grows downward).
///
/// Every region, line and panel is stored in these coordinates so that the data
/// is independent of zoom level, viewport and working-resolution downscaling.
public struct PixelRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public init(_ r: CGRect) {
        self.init(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.width), height: Double(r.height))
    }

    public static let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var center: PixelPoint { PixelPoint(x: midX, y: midY) }
    public var area: Double { max(0, width) * max(0, height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func union(_ o: PixelRect) -> PixelRect {
        if isEmpty { return o }
        if o.isEmpty { return self }
        let nx = min(x, o.x), ny = min(y, o.y)
        return PixelRect(x: nx, y: ny, width: max(maxX, o.maxX) - nx, height: max(maxY, o.maxY) - ny)
    }

    public func intersection(_ o: PixelRect) -> PixelRect {
        let nx = max(x, o.x), ny = max(y, o.y)
        let w = min(maxX, o.maxX) - nx, h = min(maxY, o.maxY) - ny
        if w <= 0 || h <= 0 { return .zero }
        return PixelRect(x: nx, y: ny, width: w, height: h)
    }

    public func intersects(_ o: PixelRect) -> Bool { !intersection(o).isEmpty }

    public func contains(_ p: PixelPoint) -> Bool { p.x >= x && p.x <= maxX && p.y >= y && p.y <= maxY }

    public func contains(_ o: PixelRect) -> Bool {
        o.x >= x && o.y >= y && o.maxX <= maxX && o.maxY <= maxY
    }

    /// Intersection over union.
    public func iou(_ o: PixelRect) -> Double {
        let i = intersection(o).area
        let u = area + o.area - i
        return u > 0 ? i / u : 0
    }

    /// Fraction of `self` covered by `o`.
    public func coverage(by o: PixelRect) -> Double {
        area > 0 ? intersection(o).area / area : 0
    }

    public func insetBy(dx: Double, dy: Double) -> PixelRect {
        PixelRect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }

    public func scaled(by s: Double) -> PixelRect {
        PixelRect(x: x * s, y: y * s, width: width * s, height: height * s)
    }

    public func offsetBy(dx: Double, dy: Double) -> PixelRect {
        PixelRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// Clamp to an image of the given size.
    public func clamped(width w: Double, height h: Double) -> PixelRect {
        intersection(PixelRect(x: 0, y: 0, width: w, height: h))
    }

    /// Snap outward to whole pixels.
    public var integral: PixelRect {
        let nx = floor(x), ny = floor(y)
        return PixelRect(x: nx, y: ny, width: ceil(maxX) - nx, height: ceil(maxY) - ny)
    }
}

public enum CoordinateConverter {
    /// Converts a Vision normalized rect (origin bottom-left, 0…1) inside `region`
    /// (pixel space of the full image) to a full-image pixel rect (origin top-left).
    public static func pixelRect(fromVisionNormalized r: CGRect, in region: PixelRect) -> PixelRect {
        PixelRect(
            x: region.x + Double(r.minX) * region.width,
            y: region.y + (1 - Double(r.maxY)) * region.height,
            width: Double(r.width) * region.width,
            height: Double(r.height) * region.height
        )
    }

    /// Converts a pixel-space point (top-left origin) to a Core Graphics point in a
    /// bitmap context of the given height (bottom-left origin).
    public static func cgPoint(_ p: PixelPoint, imageHeight: Double) -> CGPoint {
        CGPoint(x: p.x, y: imageHeight - p.y)
    }

    /// Converts a pixel-space rect (top-left origin) to Core Graphics space (bottom-left).
    public static func cgRect(_ r: PixelRect, imageHeight: Double) -> CGRect {
        CGRect(x: r.x, y: imageHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Maps a rect found on a downscaled working image back to source pixels.
    public static func toSource(_ r: PixelRect, workingScale: Double) -> PixelRect {
        workingScale == 0 ? r : r.scaled(by: 1 / workingScale)
    }

    /// Maps a view-space point to source pixels given a zoom factor and content offset.
    public static func sourcePoint(viewPoint: CGPoint, zoom: Double, offset: CGPoint = .zero) -> PixelPoint {
        PixelPoint(x: (Double(viewPoint.x) - Double(offset.x)) / zoom, y: (Double(viewPoint.y) - Double(offset.y)) / zoom)
    }
}

public enum PolygonMath {
    public static func boundingRect(_ pts: [PixelPoint]) -> PixelRect {
        guard let f = pts.first else { return .zero }
        var minX = f.x, minY = f.y, maxX = f.x, maxY = f.y
        for p in pts { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
        return PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Even-odd point in polygon test.
    public static func contains(_ pts: [PixelPoint], _ p: PixelPoint) -> Bool {
        guard pts.count >= 3 else { return false }
        var inside = false
        var j = pts.count - 1
        for i in 0..<pts.count {
            let a = pts[i], b = pts[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    public static func area(_ pts: [PixelPoint]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) / 2
    }

    /// Ramer–Douglas–Peucker simplification.
    public static func simplify(_ pts: [PixelPoint], tolerance: Double) -> [PixelPoint] {
        guard pts.count > 3 else { return pts }
        func perp(_ p: PixelPoint, _ a: PixelPoint, _ b: PixelPoint) -> Double {
            let dx = b.x - a.x, dy = b.y - a.y
            let len = (dx * dx + dy * dy).squareRoot()
            if len == 0 { return ((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)).squareRoot() }
            return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len
        }
        func rdp(_ s: ArraySlice<PixelPoint>) -> [PixelPoint] {
            guard s.count > 2, let first = s.first, let last = s.last else { return Array(s) }
            var maxD = 0.0, idx = s.startIndex
            for i in s.index(after: s.startIndex)..<s.index(before: s.endIndex) {
                let d = perp(s[i], first, last)
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > tolerance {
                let l = rdp(s[s.startIndex...idx]), r = rdp(s[idx..<s.endIndex])
                return Array(l.dropLast()) + r
            }
            return [first, last]
        }
        return rdp(pts[...])
    }

    /// Andrew's monotone chain convex hull.
    public static func convexHull(_ input: [PixelPoint]) -> [PixelPoint] {
        let pts = input.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard pts.count > 2 else { return pts }
        func cross(_ o: PixelPoint, _ a: PixelPoint, _ b: PixelPoint) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [PixelPoint] = [], upper: [PixelPoint] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}
