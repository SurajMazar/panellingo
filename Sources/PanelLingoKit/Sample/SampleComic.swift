import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Procedurally drawn, original sample comics (no third-party artwork) used for the demo
/// project and test fixtures. Characters “Haru” and “Mio” are invented for PanelLingo.
public enum SampleComic {
    /// Top-left-origin drawing helper over a Core Graphics bitmap.
    final class Canvas {
        let ctx: CGContext
        let w: Double, h: Double
        init(width: Int, height: Int) {
            w = Double(width); h = Double(height)
            ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: RGBAImage.colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setLineJoin(.round); ctx.setLineCap(.round)
        }
        func r(_ x: Double, _ y: Double, _ rw: Double, _ rh: Double) -> CGRect { CGRect(x: x, y: h - y - rh, width: rw, height: rh) }
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: h - y) }

        func panel(_ x: Double, _ y: Double, _ pw: Double, _ ph: Double) {
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(6)
            ctx.stroke(r(x, y, pw, ph))
        }

        func screentone(_ x: Double, _ y: Double, _ tw: Double, _ th: Double, spacing: Double = 9, radius: Double = 2.2) {
            ctx.saveGState(); ctx.clip(to: r(x, y, tw, th))
            ctx.setFillColor(CGColor(gray: 0.35, alpha: 1))
            var row = 0
            var yy = y
            while yy < y + th {
                var xx = x + (row % 2 == 0 ? 0 : spacing / 2)
                while xx < x + tw { ctx.fillEllipse(in: r(xx - radius, yy - radius, radius * 2, radius * 2)); xx += spacing }
                yy += spacing * 0.87; row += 1
            }
            ctx.restoreGState()
        }

        /// Speech bubble: ellipse + tail with a single merged outline.
        func bubble(_ x: Double, _ y: Double, _ bw: Double, _ bh: Double, tail: (Double, Double)?, rect: Bool = false, fill: Double = 1) {
            let shape = CGMutablePath()
            if rect { shape.addRect(r(x, y, bw, bh)) } else { shape.addEllipse(in: r(x, y, bw, bh)) }
            let tailPath = CGMutablePath()
            if let (tx, ty) = tail {
                let cx = x + bw / 2, cy = y + bh / 2
                let ang = atan2(ty - cy, tx - cx), spread = 0.16
                let ex = { (a: Double) in (cx + cos(a) * bw * 0.42, cy + sin(a) * bh * 0.42) }
                let a1 = ex(ang - spread), a2 = ex(ang + spread)
                tailPath.move(to: p(a1.0, a1.1)); tailPath.addLine(to: p(tx, ty)); tailPath.addLine(to: p(a2.0, a2.1)); tailPath.closeSubpath()
            }
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(4)
            ctx.addPath(shape); ctx.addPath(tailPath); ctx.strokePath()
            ctx.setFillColor(CGColor(gray: fill, alpha: 1))
            ctx.addPath(shape); ctx.fillPath()
            ctx.addPath(tailPath); ctx.fillPath()
        }

        func text(_ s: String, in rect: CGRect, font: String, size: Double, vertical: Bool, bold: Bool = true, color: CGColor = CGColor(gray: 0, alpha: 1)) {
            var f = NSFontManager.shared.font(withFamily: font, traits: bold ? .boldFontMask : [], weight: bold ? 9 : 5, size: size)
                ?? NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
            if f.familyName != font, let alt = NSFont(name: font, size: size) { f = alt }
            let para = NSMutableParagraphStyle(); para.alignment = .center
            var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor(cgColor: color) ?? .black, .paragraphStyle: para]
            if vertical { attrs[.verticalGlyphForm] = 1 }
            let attr = NSAttributedString(string: s, attributes: attrs)
            let fs = CTFramesetterCreateWithAttributedString(attr)
            let frameAttrs: CFDictionary? = vertical ? [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary : nil
            // Centre the text block inside the rect.
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(), frameAttrs, rect.size, nil)
            let tight = CGRect(x: rect.midX - suggested.width / 2 - 1, y: rect.midY - suggested.height / 2 - 1,
                               width: suggested.width + 2, height: suggested.height + 2)
            let frame = CTFramesetterCreateFrame(fs, CFRange(), CGPath(rect: vertical ? tight : CGRect(x: rect.minX, y: tight.minY, width: rect.width, height: tight.height), transform: nil), frameAttrs)
            ctx.textMatrix = .identity
            CTFrameDraw(frame, ctx)
        }

        /// Simple invented doodle character head.
        func character(_ cx: Double, _ cy: Double, _ size: Double, hair: Double, eyesClosed: Bool = false, sweat: Bool = false) {
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(4)
            // Body
            ctx.setFillColor(CGColor(gray: 0.82, alpha: 1))
            let body = CGMutablePath()
            body.move(to: p(cx - size * 0.55, cy + size * 1.15)); body.addLine(to: p(cx - size * 0.35, cy + size * 0.45))
            body.addLine(to: p(cx + size * 0.35, cy + size * 0.45)); body.addLine(to: p(cx + size * 0.55, cy + size * 1.15))
            ctx.addPath(body); ctx.drawPath(using: .fillStroke)
            // Head
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.addEllipse(in: r(cx - size / 2, cy - size / 2, size, size)); ctx.drawPath(using: .fillStroke)
            // Hair
            ctx.setFillColor(CGColor(gray: hair, alpha: 1))
            let hp = CGMutablePath()
            hp.addArc(center: p(cx, cy), radius: size / 2 + 2, startAngle: 0.05 * .pi, endAngle: 0.95 * .pi, clockwise: false)
            hp.addQuadCurve(to: p(cx + size * 0.47, cy - size * 0.05), control: p(cx, cy - size * 0.05))
            ctx.addPath(hp); ctx.drawPath(using: .fillStroke)
            // Eyes
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for dx in [-0.17, 0.17] {
                if eyesClosed {
                    ctx.move(to: p(cx + size * dx - 8, cy + size * 0.1)); ctx.addLine(to: p(cx + size * dx + 8, cy + size * 0.1)); ctx.strokePath()
                } else {
                    ctx.fillEllipse(in: r(cx + size * dx - 6, cy + size * 0.04, 12, 18))
                }
            }
            // Mouth
            ctx.move(to: p(cx - 8, cy + size * 0.28)); ctx.addQuadCurve(to: p(cx + 8, cy + size * 0.28), control: p(cx, cy + size * 0.34)); ctx.strokePath()
            if sweat {
                ctx.setFillColor(CGColor(srgbRed: 0.7, green: 0.85, blue: 1, alpha: 1))
                ctx.addEllipse(in: r(cx + size * 0.45, cy - size * 0.2, 14, 22)); ctx.drawPath(using: .fillStroke)
            }
        }

        func image() -> CGImage { ctx.makeImage()! }
    }

    static let jpFont = "Hiragino Sans"

    /// Manga-style page (right-to-left) with vertical Japanese bubbles, a caption, SFX and screentone.
    public static func japanesePage() -> CGImage {
        let c = Canvas(width: 1200, height: 1700)
        // Panel 1 (top, full width)
        c.panel(40, 40, 1120, 760)
        c.character(820, 520, 230, hair: 0.25)
        c.character(330, 540, 220, hair: 0.6, eyesClosed: true)
        c.bubble(1010, 70, 110, 190, tail: nil, rect: true)                         // caption
        c.text("翌朝", in: c.r(1010, 70, 110, 190), font: jpFont, size: 44, vertical: true)
        c.bubble(820, 90, 170, 330, tail: (830, 400))                               // A
        c.text("ハル、\nおはよう！", in: c.r(845, 120, 120, 270), font: jpFont, size: 40, vertical: true)
        c.bubble(140, 100, 180, 360, tail: (300, 420))                              // B
        c.text("ミオ…\nまだ眠いよ。", in: c.r(165, 130, 130, 300), font: jpFont, size: 38, vertical: true)
        // Panel 2 (bottom right) with screentone background
        c.panel(620, 840, 540, 820)
        c.screentone(623, 843, 534, 814)
        c.character(860, 1360, 220, hair: 0.25)
        c.bubble(700, 880, 300, 380, tail: (850, 1220))                             // C
        c.text("今日は遠足\nだよ！\n忘れたの？", in: c.r(730, 920, 240, 300), font: jpFont, size: 40, vertical: true)
        // Panel 3 (bottom left)
        c.panel(40, 840, 540, 820)
        c.character(300, 1380, 220, hair: 0.6, sweat: true)
        c.text("ドキッ", in: c.r(70, 880, 160, 360), font: jpFont, size: 96, vertical: true)  // SFX, no bubble
        c.bubble(250, 900, 300, 200, tail: (320, 1220))                             // D (horizontal)
        c.text("あっ、\nそうだった！", in: c.r(275, 930, 250, 140), font: jpFont, size: 38, vertical: false)
        return c.image()
    }

    public static func englishPage() -> CGImage {
        let c = Canvas(width: 1100, height: 1500)
        c.panel(40, 40, 1020, 700)
        c.character(280, 480, 220, hair: 0.3)
        c.character(800, 500, 220, hair: 0.7)
        c.bubble(70, 70, 420, 220, tail: (250, 360))
        c.text("HEY! ARE YOU\nAWAKE YET?", in: c.r(100, 100, 360, 160), font: "Comic Sans MS", size: 40, vertical: false)
        c.bubble(640, 80, 380, 200, tail: (780, 380))
        c.text("FIVE MORE\nMINUTES...", in: c.r(670, 110, 320, 140), font: "Comic Sans MS", size: 40, vertical: false)
        c.panel(40, 780, 1020, 680)
        c.bubble(70, 800, 360, 90, tail: nil, rect: true)
        c.text("LATER THAT DAY", in: c.r(80, 805, 340, 80), font: "Avenir Next", size: 34, vertical: false)
        c.screentone(43, 900, 1014, 557)
        c.bubble(560, 930, 440, 260, tail: (700, 1300))
        c.text("WE ARE GOING TO\nBE LATE FOR THE\nSCHOOL TRIP!", in: c.r(590, 960, 380, 200), font: "Comic Sans MS", size: 36, vertical: false)
        return c.image()
    }

    public static func koreanPage() -> CGImage {
        let c = Canvas(width: 900, height: 1200)
        c.panel(30, 30, 840, 1140)
        c.character(450, 800, 260, hair: 0.3)
        c.bubble(120, 80, 660, 300, tail: (440, 620))
        c.text("안녕하세요!\n오늘 날씨가 정말 좋네요.", in: c.r(160, 120, 580, 220), font: "Apple SD Gothic Neo", size: 44, vertical: false)
        return c.image()
    }

    public static func chinesePage() -> CGImage {
        let c = Canvas(width: 900, height: 1200)
        c.panel(30, 30, 840, 1140)
        c.character(450, 800, 260, hair: 0.5)
        c.bubble(140, 80, 620, 300, tail: (440, 620))
        c.text("你好！\n今天天气很好。", in: c.r(180, 120, 540, 220), font: "PingFang SC", size: 52, vertical: false)
        return c.image()
    }

    public static func noTextPage() -> CGImage {
        let c = Canvas(width: 900, height: 1200)
        c.panel(30, 30, 840, 1140)
        c.screentone(33, 600, 834, 567)
        c.character(300, 700, 240, hair: 0.3)
        c.character(620, 720, 240, hair: 0.7, eyesClosed: true)
        return c.image()
    }

    /// Writes a ready-to-translate sample project.
    public static func createSampleProject(at url: URL) throws -> ProjectStore {
        var settings = ProjectSettings()
        settings.sourceLanguage = "ja"; settings.targetLanguage = "en"; settings.readingDirection = .rightToLeft
        settings.storyContext = "Haru (boy, sleepy, dark hair) and Mio (girl, energetic, light hair) are childhood friends. Today is their school trip."
        let store = try ProjectStore.create(at: url, title: "PanelLingo Sample", settings: settings)
        try store.saveGlossary([
            GlossaryEntry(original: "ハル", preferred: "Haru", isCharacterName: true, notes: "sleepy boy"),
            GlossaryEntry(original: "ミオ", preferred: "Mio", isCharacterName: true, notes: "energetic girl"),
            GlossaryEntry(original: "遠足", preferred: "school trip"),
        ])
        try store.addPage(imageData: ImageIOHelper.png(japanesePage()), fileExtension: "png", name: "Sample — Morning", importedFrom: "sample")
        return store
    }
}
