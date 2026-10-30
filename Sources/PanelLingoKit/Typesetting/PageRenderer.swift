import CoreGraphics
import CoreText
import Foundation

public enum RenderMode: String, CaseIterable, Sendable, Identifiable {
    case original, cleaned, translated
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .original: "Original"
        case .cleaned: "Cleaned"
        case .translated: "Translated"
        }
    }
}

/// Access to per-region cleanup layers.
public protocol LayerSource: Sendable {
    func loadPatch(pageID: String, regionID: String) -> CGImage?
    func loadMask(pageID: String, regionID: String) -> BitMask?
}

extension ProjectStore: LayerSource {}

/// Flattens original artwork + cleaned patches + translated lettering at full source resolution.
public struct PageRenderer: Sendable {
    public var layout: TextRenderingService
    public init(layout: TextRenderingService = CoreTextLayoutEngine()) { self.layout = layout }

    public func render(page: ComicPage, original: CGImage, layers: LayerSource, mode: RenderMode,
                       targetLanguage: String, excluding: Set<String> = []) throws -> CGImage {
        if mode == .original { return original }
        guard let ctx = ImageCompose.context(for: original) else { throw PanelLingoError.stage(.typeset, "cannot allocate bitmap") }
        let H = Double(original.height)
        ctx.interpolationQuality = .none
        ctx.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        for r in page.orderedRegions where !excluding.contains(r.id) {
            drawPatch(r, page: page, layers: layers, ctx: ctx, imageHeight: H)
        }
        if mode == .translated {
            for r in page.orderedRegions where !excluding.contains(r.id) && shouldLetter(r) {
                _ = drawText(r, ctx: ctx, imageHeight: H, language: targetLanguage)
            }
        }
        guard let img = ctx.makeImage() else { throw PanelLingoError.stage(.typeset, "render failed") }
        return img
    }

    /// Lettering is drawn only where the source text was removed — or for SFX/art text, which are
    /// overlaid with an outline — so a failed cleanup never produces text-on-text.
    public func shouldLetter(_ r: TextRegion) -> Bool {
        guard !r.doNotTranslate, let t = r.translatedText, !t.isEmpty else { return false }
        switch r.cleanup.status {
        case .cleaned: return true
        case .skipped, .none, .needsReview, .failed, .restored: return r.kind == .sfx || r.kind == .artText || r.cleanup.manualMask
        }
    }

    func drawPatch(_ r: TextRegion, page: ComicPage, layers: LayerSource, ctx: CGContext, imageHeight H: Double) {
        guard r.cleanup.status == .cleaned || (r.cleanup.status == .needsReview && r.cleanup.manualMask),
              let rect = r.cleanup.maskRect,
              let patch = layers.loadPatch(pageID: page.id, regionID: r.id),
              let mask = layers.loadMask(pageID: page.id, regionID: r.id),
              let maskImage = mask.grayImage().cgImage() else { return }
        let cg = CoordinateConverter.cgRect(rect, imageHeight: H)
        ctx.saveGState()
        // Clip to the mask so pixels outside it can never change, whatever the colour space.
        ctx.clip(to: cg, mask: maskImage)
        ctx.draw(patch, in: cg)
        ctx.restoreGState()
    }

    /// Lays out and draws a region's translation. Returns the layout used.
    @discardableResult
    public func drawText(_ r: TextRegion, ctx: CGContext, imageHeight H: Double, language: String) -> TextLayoutResult? {
        guard let text = r.translatedText, !text.isEmpty else { return nil }
        let area = TextArea.forRegion(r)
        let result = layout.layout(text: text, style: r.style, area: area, language: language)
        ctx.saveGState()
        ctx.textMatrix = .identity
        if r.style.rotation != 0 {
            let c = CoordinateConverter.cgPoint(area.rect.center, imageHeight: H)
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: CGFloat(-r.style.rotation * .pi / 180))
            ctx.translateBy(x: -c.x, y: -c.y)
        }
        let stroke = r.style.strokeWidth * result.fontSize
        let sc = r.style.strokeColor, tc = r.style.textColor
        func passes(_ draw: () -> Void) {
            if stroke > 0 {
                ctx.setTextDrawingMode(.stroke)
                ctx.setLineWidth(CGFloat(stroke * 2))
                ctx.setLineJoin(.round)
                ctx.setStrokeColor(CGColor(srgbRed: sc.r, green: sc.g, blue: sc.b, alpha: sc.a))
                draw()
            }
            ctx.setTextDrawingMode(.fill)
            ctx.setFillColor(CGColor(srgbRed: tc.r, green: tc.g, blue: tc.b, alpha: tc.a))
            draw()
        }
        if result.vertical, let frame = result.frame {
            ctx.saveGState()
            let cg = CoordinateConverter.cgRect(result.bounds, imageHeight: H)
            ctx.translateBy(x: cg.minX, y: cg.minY)
            passes { CTFrameDraw(frame, ctx) }
            ctx.restoreGState()
        } else {
            passes {
                for l in result.lines {
                    ctx.textPosition = CGPoint(x: l.origin.x, y: H - l.origin.y)
                    CTLineDraw(l.line, ctx)
                }
            }
        }
        ctx.restoreGState()
        return result
    }
}
