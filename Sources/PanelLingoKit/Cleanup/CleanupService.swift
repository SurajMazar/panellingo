import CoreGraphics
import Foundation

public struct CleanupOutput: Sendable {
    public var rect: PixelRect
    public var mask: BitMask
    /// Cleaned RGBA patch covering `rect`. Only masked pixels differ from the original.
    public var patch: RGBAImage?
    public var status: CleanupStatus
    public var mode: CleanupMode
    public var message: String?
}

/// Non-destructive text removal for one region.
public struct CleanupService: Sendable {
    public var flat: InpaintingProvider = FlatFillInpainter()
    public var diffusion: InpaintingProvider = DiffusionInpainter()
    public var neural: InpaintingProvider = CoreMLInpainter()
    /// Ring standard deviation above which a background counts as "complex".
    public var complexBackgroundStd = 18.0
    /// Ring standard deviation above which automatic cleanup is not trusted.
    public var unsafeBackgroundStd = 55.0
    public init() {}

    /// Builds the automatic mask (text pixels, dilated, kept inside the bubble interior).
    public func automaticMask(image: CGImage, region: TextRegion) -> (rect: PixelRect, mask: BitMask, enclosed: Bool) {
        let rm = TextMaskBuilder.build(image: image, region: region)
        var mask = rm.text.dilated(Int(region.cleanup.maskExpansion.rounded()))
        if let shape = rm.shape {
            // Never touch the bubble outline: stay one pixel inside the interior.
            mask = mask & shape.eroded(1)
        }
        return (rm.rect, mask, rm.shape != nil)
    }

    /// Cleans a region. `manualMask` (rect + mask) overrides the automatic mask.
    public func clean(image: CGImage, region: TextRegion, mode: CleanupMode,
                      manualMask: (PixelRect, BitMask)? = nil) throws -> CleanupOutput {
        let rect: PixelRect, mask: BitMask, enclosed: Bool
        if let (r, m) = manualMask { rect = r; mask = m; enclosed = region.kind.isEnclosed }
        else { (rect, mask, enclosed) = automaticMask(image: image, region: region) }

        guard !mask.isEmpty else {
            return CleanupOutput(rect: rect, mask: mask, patch: nil, status: .skipped, mode: mode, message: "No lettering pixels found")
        }
        let crop = RGBAImage(image, crop: rect)
        guard crop.width == mask.width, crop.height == mask.height else {
            throw PanelLingoError.stage(.clean, "mask size mismatch")
        }
        let coverage = Double(mask.count) / Double(mask.bits.count)
        let ring = RingStats(crop, mask: mask)
        let manual = manualMask != nil

        // Refuse risky automatic cleanups: leave the original visible and ask for review.
        if !manual && !enclosed && (ring.std > unsafeBackgroundStd || coverage > 0.5) {
            return CleanupOutput(rect: rect, mask: mask, patch: nil, status: .needsReview, mode: mode,
                                 message: "Text sits on complex artwork; review the mask or paint it manually")
        }

        var used = mode
        let provider: InpaintingProvider
        switch mode {
        case .fast: provider = flat
        case .balanced: provider = ring.std <= complexBackgroundStd ? flat : diffusion
        case .quality:
            if neural.isAvailable { provider = neural } else { provider = ring.std <= complexBackgroundStd ? flat : diffusion; used = .balanced }
        }
        let patch = try provider.inpaint(crop, mask: mask, feather: region.cleanup.feather)
        var status: CleanupStatus = .cleaned
        var message: String? = mode == .quality && used != .quality ? "Neural model not installed — used diffusion" : nil
        if mode == .fast && ring.std > complexBackgroundStd {
            status = .needsReview
            message = "Flat fill on a textured background; try Balanced mode"
        } else if ring.std > complexBackgroundStd * 2 {
            status = .needsReview
            message = "Background is textured; check the cleanup"
        }
        return CleanupOutput(rect: rect, mask: mask, patch: patch, status: status, mode: used, message: message)
    }

    /// Applies a brush stroke to a mask (in source pixels). `add == false` erases.
    public static func paint(_ mask: inout BitMask, maskRect: PixelRect, points: [PixelPoint], radius: Double, add: Bool) {
        let r = max(1, radius), r2 = r * r
        var prev: PixelPoint?
        for p in points {
            let segment: [PixelPoint]
            if let q = prev {
                let d = max(1, Int(((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)).squareRoot() / max(1, r / 2)))
                segment = (1...d).map { k in PixelPoint(x: q.x + (p.x - q.x) * Double(k) / Double(d), y: q.y + (p.y - q.y) * Double(k) / Double(d)) }
            } else { segment = [p] }
            for s in segment {
                let cx = s.x - maskRect.x, cy = s.y - maskRect.y
                let y0 = max(0, Int(cy - r)), y1 = min(mask.height - 1, Int(cy + r))
                let x0 = max(0, Int(cx - r)), x1 = min(mask.width - 1, Int(cx + r))
                guard y0 <= y1, x0 <= x1 else { continue }
                for y in y0...y1 {
                    for x in x0...x1 {
                        let dx = Double(x) - cx, dy = Double(y) - cy
                        if dx * dx + dy * dy <= r2 { mask[x, y] = add }
                    }
                }
            }
            prev = p
        }
    }
}
