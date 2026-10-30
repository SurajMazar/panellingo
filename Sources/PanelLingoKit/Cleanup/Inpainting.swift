import CoreGraphics
import Foundation

public protocol InpaintingProvider: Sendable {
    var name: String { get }
    var isAvailable: Bool { get }
    /// Returns `image` with masked pixels reconstructed. Unmasked pixels must be returned unchanged.
    func inpaint(_ image: RGBAImage, mask: BitMask, feather: Double) throws -> RGBAImage
}

/// Statistics of the pixels surrounding a mask: used to pick a strategy and judge risk.
public struct RingStats: Sendable {
    public var mean: [Double]
    public var median: [UInt8]
    public var std: Double
    public var count: Int

    public init(_ img: RGBAImage, mask: BitMask, width ringWidth: Int = 3) {
        let ring = mask.dilated(ringWidth)
        var vals: [[Int]] = [[], [], []]
        for i in 0..<mask.bits.count where ring.bits[i] != 0 && mask.bits[i] == 0 {
            for c in 0..<3 { vals[c].append(Int(img.pixels[i * 4 + c])) }
        }
        count = vals[0].count
        mean = vals.map { $0.isEmpty ? 255 : Double($0.reduce(0, +)) / Double($0.count) }
        median = vals.map { v in v.isEmpty ? 255 : UInt8(v.sorted()[v.count / 2]) }
        var s = 0.0
        for c in 0..<3 { for v in vals[c] { s += (Double(v) - mean[c]) * (Double(v) - mean[c]) } }
        std = count > 0 ? (s / Double(count * 3)).squareRoot() : 0
    }
}

/// Distance (in pixels, capped) from each masked pixel to the nearest unmasked pixel.
func maskDistance(_ mask: BitMask, cap: Int) -> [Int] {
    var d = [Int](repeating: 0, count: mask.bits.count)
    var frontier: [Int] = []
    let w = mask.width, h = mask.height
    for i in 0..<mask.bits.count where mask.bits[i] != 0 {
        let x = i % w, y = i / w
        let edge = x == 0 || y == 0 || x == w - 1 || y == h - 1 || mask.bits[i - 1] == 0 || mask.bits[i + 1] == 0
            || mask.bits[i - w] == 0 || mask.bits[i + w] == 0
        if edge { d[i] = 1; frontier.append(i) } else { d[i] = Int.max }
    }
    var level = 1
    while !frontier.isEmpty && level < cap {
        var next: [Int] = []
        for i in frontier {
            let x = i % w, y = i / w
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                let j = ny * w + nx
                if mask.bits[j] != 0 && d[j] == Int.max { d[j] = level + 1; next.append(j) }
            }
        }
        frontier = next; level += 1
    }
    return d.map { $0 == Int.max ? cap : $0 }
}

/// Flat fill with the surrounding paper colour. Ideal for white / uniform bubbles.
public struct FlatFillInpainter: InpaintingProvider {
    public let name = "Flat fill"
    public var isAvailable: Bool { true }
    public init() {}

    public func inpaint(_ image: RGBAImage, mask: BitMask, feather: Double) throws -> RGBAImage {
        let stats = RingStats(image, mask: mask)
        var out = image
        let dist = feather > 0 ? maskDistance(mask, cap: Int(feather.rounded(.up)) + 1) : []
        for i in 0..<mask.bits.count where mask.bits[i] != 0 {
            let t = feather > 0 ? min(1, Double(dist[i]) / (feather + 1)) : 1
            for c in 0..<3 {
                let o = Double(image.pixels[i * 4 + c]), f = Double(stats.median[c])
                // Pixels darker than paper are lettering: replace fully. Lighter pixels near the
                // mask edge blend smoothly so no hard seam appears.
                let v = o < f ? f : o * (1 - t) + f * t
                out.pixels[i * 4 + c] = UInt8(clamping: Int(v.rounded()))
            }
            out.pixels[i * 4 + 3] = 255
        }
        return out
    }
}

/// Onion-peel fill followed by harmonic (Laplace) smoothing. Reconstructs gradients and soft
/// shading behind text on non-flat backgrounds without any neural model.
public struct DiffusionInpainter: InpaintingProvider {
    public let name = "Diffusion"
    public var isAvailable: Bool { true }
    public var smoothingIterations = 40
    public init() {}

    public func inpaint(_ image: RGBAImage, mask: BitMask, feather: Double) throws -> RGBAImage {
        let w = mask.width, h = mask.height
        var px = image.pixels.map { Float($0) }
        var known = mask.bits.map { $0 == 0 }
        // 1. Onion peel: repeatedly fill boundary pixels with the mean of known neighbours.
        var remaining = mask.bits.enumerated().filter { $0.element != 0 }.map(\.offset)
        var guardCount = 0
        while !remaining.isEmpty && guardCount < 4096 {
            guardCount += 1
            var filled: [(Int, [Float])] = []
            var still: [Int] = []
            for i in remaining {
                let x = i % w, y = i / w
                var sum: [Float] = [0, 0, 0], n: Float = 0
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let j = ny * w + nx
                    if known[j] { let wt: Float = (dx == 0 || dy == 0) ? 1 : 0.7; for c in 0..<3 { sum[c] += px[j * 4 + c] * wt }; n += wt }
                } }
                if n > 0 { filled.append((i, sum.map { $0 / n })) } else { still.append(i) }
            }
            if filled.isEmpty { break }
            for (i, v) in filled { for c in 0..<3 { px[i * 4 + c] = v[c] }; px[i * 4 + 3] = 255; known[i] = true }
            remaining = still
        }
        // 2. Harmonic smoothing restricted to masked pixels (Gauss–Seidel).
        let masked = mask.bits.enumerated().filter { $0.element != 0 }.map(\.offset)
        for _ in 0..<smoothingIterations {
            for i in masked {
                let x = i % w, y = i / w
                var sum: [Float] = [0, 0, 0], n: Float = 0
                if x > 0 { for c in 0..<3 { sum[c] += px[(i - 1) * 4 + c] }; n += 1 }
                if x < w - 1 { for c in 0..<3 { sum[c] += px[(i + 1) * 4 + c] }; n += 1 }
                if y > 0 { for c in 0..<3 { sum[c] += px[(i - w) * 4 + c] }; n += 1 }
                if y < h - 1 { for c in 0..<3 { sum[c] += px[(i + w) * 4 + c] }; n += 1 }
                if n > 0 { for c in 0..<3 { px[i * 4 + c] = sum[c] / n } }
            }
        }
        var out = image
        for i in masked {
            for c in 0..<3 { out.pixels[i * 4 + c] = UInt8(clamping: Int(px[i * 4 + c].rounded())) }
            out.pixels[i * 4 + 3] = 255
        }
        return out
    }
}

/// Optional neural inpainting (LaMa-style Core ML model supplied by the user).
///
/// No model is bundled (size and licensing). When none is installed this provider reports
/// unavailable and the pipeline uses `DiffusionInpainter` instead.
public struct CoreMLInpainter: InpaintingProvider {
    public let name = "Neural (Core ML)"
    public init() {}
    public static var modelURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PanelLingo/Models/Inpainting.mlmodelc")
    }
    public var isAvailable: Bool { false }
    public func inpaint(_ image: RGBAImage, mask: BitMask, feather: Double) throws -> RGBAImage {
        throw PanelLingoError.stage(.clean, "No neural inpainting model is installed")
    }
}
