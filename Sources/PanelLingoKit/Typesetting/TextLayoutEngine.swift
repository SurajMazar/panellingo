import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Usable lettering area: a rectangle plus optional bubble outline for shape-aware wrapping.
public struct TextArea: Sendable {
    public var rect: PixelRect
    public var polygon: [PixelPoint]?
    public var inset: Double

    public init(rect: PixelRect, polygon: [PixelPoint]?, inset: Double) {
        self.rect = rect; self.polygon = polygon; self.inset = inset
    }

    public static func forRegion(_ r: TextRegion) -> TextArea {
        let rect = r.textArea ?? r.bbox
        let poly = r.textArea == nil ? r.polygon : nil
        return TextArea(rect: rect, polygon: poly, inset: r.style.padding * min(rect.width, rect.height))
    }

    public var verticalRange: ClosedRange<Double> { (rect.minY + inset)...(rect.maxY - inset) }

    /// Horizontal span usable across the band [y0, y1].
    public func span(y0: Double, y1: Double) -> (Double, Double)? {
        var lo = rect.minX + inset, hi = rect.maxX - inset
        guard let poly = polygon, poly.count >= 3 else { return lo < hi ? (lo, hi) : nil }
        let cx = rect.midX
        let steps = max(2, Int((y1 - y0) / 2))
        for k in 0...steps {
            let y = y0 + (y1 - y0) * Double(k) / Double(steps)
            guard let (a, b) = Self.interval(poly, y: y, around: cx) else { return nil }
            lo = max(lo, a + inset); hi = min(hi, b - inset)
        }
        return hi - lo > 1 ? (lo, hi) : nil
    }

    /// Interior interval of the polygon on scanline `y` containing (or closest to) `cx`.
    static func interval(_ poly: [PixelPoint], y: Double, around cx: Double) -> (Double, Double)? {
        var xs: [Double] = []
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            if (a.y <= y && b.y > y) || (b.y <= y && a.y > y) {
                xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
            }
        }
        xs.sort()
        var best: (Double, Double)?
        var i = 0
        while i + 1 < xs.count {
            let iv = (xs[i], xs[i + 1])
            if iv.0 <= cx && cx <= iv.1 { return iv }
            if best == nil || (iv.1 - iv.0) > (best!.1 - best!.0) { best = iv }
            i += 2
        }
        return best
    }
}

public struct LaidOutLine: @unchecked Sendable {
    public var line: CTLine
    /// Baseline origin in source pixel space (top-left origin).
    public var origin: CGPoint
    public var width: Double
}

public struct TextLayoutResult: @unchecked Sendable {
    public var fontSize: Double
    public var lines: [LaidOutLine]
    public var overflow: Bool
    public var bounds: PixelRect
    public var vertical: Bool
    /// For vertical layout: the frame drawn in `bounds`.
    public var frame: CTFrame?
}

public protocol TextRenderingService: Sendable {
    func layout(text: String, style: TextStyle, area: TextArea, language: String) -> TextLayoutResult
}

public enum FontResolver {
    public static func font(_ style: TextStyle, size: Double) -> CTFont {
        let s = CGFloat(size)
        var font: NSFont?
        if style.fontFamily == "SF Pro Rounded" || style.fontFamily == "System Rounded" {
            let base = NSFont.systemFont(ofSize: s, weight: style.bold ? .bold : .regular)
            if let d = base.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: s) }
        } else if style.fontFamily == "System" {
            font = NSFont.systemFont(ofSize: s, weight: style.bold ? .bold : .regular)
        } else {
            var traits: NSFontTraitMask = []
            if style.bold { traits.insert(.boldFontMask) }
            if style.italic { traits.insert(.italicFontMask) }
            font = NSFontManager.shared.font(withFamily: style.fontFamily, traits: traits, weight: style.bold ? 9 : 5, size: s)
                ?? NSFontManager.shared.font(withFamily: style.fontFamily, traits: [], weight: 5, size: s)
        }
        return (font ?? NSFont.systemFont(ofSize: s, weight: style.bold ? .bold : .regular)) as CTFont
    }

    public static func isInstalled(_ family: String) -> Bool {
        ["SF Pro Rounded", "System Rounded", "System"].contains(family) || NSFontManager.shared.availableMembers(ofFontFamily: family) != nil
    }
}

/// Core Text based auto-fitting layout.
public struct CoreTextLayoutEngine: TextRenderingService {
    public init() {}

    public func layout(text raw: String, style: TextStyle, area: TextArea, language: String) -> TextLayoutResult {
        let text = Self.normalise(style.uppercase ? raw.uppercased(with: Locale(identifier: language)) : raw)
        let info = LanguageInfo.info(language)
        let vertical = style.direction == .vertical && (info?.supportsVertical ?? false)
        if text.isEmpty {
            return TextLayoutResult(fontSize: style.fontSize ?? style.minFontSize, lines: [], overflow: false, bounds: area.rect, vertical: vertical)
        }
        if vertical { return layoutVertical(text, style: style, area: area) }
        let rtl = info?.isRTL ?? false
        let breaksOnSpaces = info?.usesSpaces ?? true

        if let fixed = style.fontSize {
            let r = attempt(text, style: style, size: fixed, area: area, rtl: rtl, spaces: breaksOnSpaces, strict: false)
            return r ?? forced(text, style: style, size: fixed, area: area, rtl: rtl)
        }
        let maxSize = min(style.maxFontSize, max(style.minFontSize, (area.verticalRange.upperBound - area.verticalRange.lowerBound) * 0.9))
        var lo = style.minFontSize, hi = maxSize
        var best: TextLayoutResult? = attempt(text, style: style, size: lo, area: area, rtl: rtl, spaces: breaksOnSpaces, strict: true)
        if best == nil {
            // Allow mid-word breaks at minimum size before declaring overflow.
            if let r = attempt(text, style: style, size: lo, area: area, rtl: rtl, spaces: breaksOnSpaces, strict: false) { return r }
            return forced(text, style: style, size: lo, area: area, rtl: rtl)
        }
        while hi - lo > 0.5 {
            let mid = (lo + hi) / 2
            if let r = attempt(text, style: style, size: mid, area: area, rtl: rtl, spaces: breaksOnSpaces, strict: true) {
                best = r; lo = mid
            } else { hi = mid }
        }
        return best!
    }

    /// Lettering clean-up: "..." → "…", trimmed whitespace.
    static func normalise(_ s: String) -> String {
        s.replacingOccurrences(of: "...", with: "…").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A line may end at `index` only after whitespace or a hyphen/dash/slash (never inside "word…").
    static func isBreakOpportunity(_ ns: NSString, at index: Int) -> Bool {
        let prev = ns.character(at: index - 1), next = ns.character(at: index)
        let ws = CharacterSet.whitespacesAndNewlines
        if let p = UnicodeScalar(prev), ws.contains(p) { return true }
        if let n = UnicodeScalar(next), ws.contains(n) { return true }
        return [0x2D, 0x2010, 0x2013, 0x2014, 0x2F].contains(Int(prev))
    }

    func attributed(_ text: String, style: TextStyle, size: Double, rtl: Bool) -> NSAttributedString {
        let font = FontResolver.font(style, size: size)
        let para = NSMutableParagraphStyle()
        para.baseWritingDirection = rtl ? .rightToLeft : .natural
        return NSAttributedString(string: text, attributes: [
            .font: font,
            // Colours come from the drawing context so the renderer can do stroke + fill passes.
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            .paragraphStyle: para,
        ])
    }

    func metrics(_ style: TextStyle, size: Double) -> (ascent: Double, descent: Double, lineHeight: Double) {
        let f = FontResolver.font(style, size: size)
        let a = Double(CTFontGetAscent(f)), d = Double(CTFontGetDescent(f))
        return (a, d, (a + d) * style.lineSpacing)
    }

    /// Tries to lay out at `size`; nil if it does not fit. `strict` forbids breaking inside words.
    func attempt(_ text: String, style: TextStyle, size: Double, area: TextArea, rtl: Bool, spaces: Bool, strict: Bool) -> TextLayoutResult? {
        let attr = attributed(text, style: style, size: size, rtl: rtl)
        let ts = CTTypesetterCreateWithAttributedString(attr)
        let (ascent, descent, lh) = metrics(style, size: size)
        let vr = area.verticalRange
        let availH = vr.upperBound - vr.lowerBound
        guard availH > 0 else { return nil }
        let maxLines = max(1, Int(availH / lh))
        let ns = text as NSString
        // Shape centre for vertical centring.
        let centerY = (vr.lowerBound + vr.upperBound) / 2
        for n in 1...maxLines {
            let blockH = Double(n) * lh
            var top = centerY - blockH / 2
            top = min(max(top, vr.lowerBound), vr.upperBound - blockH)
            var lines: [LaidOutLine] = []
            var start = 0
            var ok = true
            for i in 0..<n {
                guard start < ns.length else { break }
                let y0 = top + Double(i) * lh, y1 = y0 + lh
                guard let (a, b) = area.span(y0: y0, y1: y1) else { ok = false; break }
                let width = b - a
                // Hard line breaks in the source text are honoured.
                var count = CTTypesetterSuggestLineBreak(ts, start, width)
                let nl = ns.range(of: "\n", options: [], range: NSRange(location: start, length: ns.length - start))
                if nl.location != NSNotFound, nl.location < start + count { count = nl.location - start + 1 }
                if count <= 0 { ok = false; break }
                let end = start + count
                if strict && spaces && end < ns.length && !Self.isBreakOpportunity(ns, at: end) { ok = false; break }
                let trimmed = CTLineCreateWithAttributedString(attr.attributedSubstring(from: NSRange(location: start, length: count)).trimmed)
                let lw = Double(CTLineGetTypographicBounds(trimmed, nil, nil, nil))
                if lw > width + 0.5 { ok = false; break }
                let x: Double
                switch style.alignment {
                case .center: x = a + (width - lw) / 2
                case .leading: x = rtl ? b - lw : a
                case .trailing: x = rtl ? a : b - lw
                }
                let baseline = y0 + (lh - (ascent + descent)) / 2 + ascent
                lines.append(LaidOutLine(line: trimmed, origin: CGPoint(x: x, y: baseline), width: lw))
                start = end
            }
            if ok && start >= ns.length {
                let bounds = lines.reduce(PixelRect.zero) { acc, l in
                    acc.union(PixelRect(x: l.origin.x, y: l.origin.y - ascent, width: l.width, height: ascent + descent))
                }
                return TextLayoutResult(fontSize: size, lines: lines, overflow: false, bounds: bounds, vertical: false)
            }
        }
        return nil
    }

    /// Last resort: rectangle wrapping at `size`; text may extend beyond the area (flagged overflow).
    func forced(_ text: String, style: TextStyle, size: Double, area: TextArea, rtl: Bool) -> TextLayoutResult {
        let attr = attributed(text, style: style, size: size, rtl: rtl)
        let ts = CTTypesetterCreateWithAttributedString(attr)
        let (ascent, descent, lh) = metrics(style, size: size)
        let width = max(10, area.rect.width - 2 * area.inset)
        var raw: [(CTLine, Double)] = []
        var start = 0
        let len = (text as NSString).length
        while start < len && raw.count < 200 {
            let count = max(1, CTTypesetterSuggestLineBreak(ts, start, width))
            let l = CTLineCreateWithAttributedString(attr.attributedSubstring(from: NSRange(location: start, length: count)).trimmed)
            raw.append((l, Double(CTLineGetTypographicBounds(l, nil, nil, nil))))
            start += count
        }
        let blockH = Double(raw.count) * lh
        let top = area.rect.midY - blockH / 2
        let lines = raw.enumerated().map { i, e in
            LaidOutLine(line: e.0, origin: CGPoint(x: area.rect.midX - e.1 / 2, y: top + Double(i) * lh + ascent), width: e.1)
        }
        let bounds = PixelRect(x: area.rect.midX - (raw.map(\.1).max() ?? 0) / 2, y: top, width: raw.map(\.1).max() ?? 0, height: blockH)
        let overflow = blockH > area.rect.height - 2 * area.inset || (raw.map(\.1).max() ?? 0) > width + 0.5
        _ = descent
        return TextLayoutResult(fontSize: size, lines: lines, overflow: overflow, bounds: bounds, vertical: false)
    }

    /// Vertical CJK layout with Core Text frames (columns right-to-left).
    func layoutVertical(_ text: String, style: TextStyle, area: TextArea) -> TextLayoutResult {
        let rect = area.rect.insetBy(dx: area.inset, dy: area.inset)
        func frame(_ size: Double) -> (CTFrame, Bool) {
            let font = FontResolver.font(style, size: size)
            let attr = NSAttributedString(string: text, attributes: [
                .font: font, .verticalGlyphForm: 1,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
            let fs = CTFramesetterCreateWithAttributedString(attr)
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: rect.height), transform: nil)
            let attrs = [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary
            let f = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, attrs)
            let visible = CTFrameGetVisibleStringRange(f)
            return (f, visible.length >= (text as NSString).length)
        }
        if let s = style.fontSize { let (f, fits) = frame(s); return .init(fontSize: s, lines: [], overflow: !fits, bounds: rect, vertical: true, frame: f) }
        var lo = style.minFontSize, hi = min(style.maxFontSize, rect.width * 0.9)
        var best = frame(lo)
        if !best.1 { return .init(fontSize: lo, lines: [], overflow: true, bounds: rect, vertical: true, frame: best.0) }
        while hi - lo > 0.5 {
            let mid = (lo + hi) / 2
            let f = frame(mid)
            if f.1 { best = f; lo = mid } else { hi = mid }
        }
        return .init(fontSize: lo, lines: [], overflow: false, bounds: rect, vertical: true, frame: best.0)
    }
}

extension NSAttributedString {
    /// Copy without trailing whitespace/newlines (so measured width excludes them).
    var trimmed: NSAttributedString {
        let s = string as NSString
        var end = s.length
        while end > 0, let u = UnicodeScalar(s.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(u) { end -= 1 }
        return attributedSubstring(from: NSRange(location: 0, length: end))
    }
}
