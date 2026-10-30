// Draws the PanelLingo app icon (speech bubble + translation glyphs) and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit
import Foundation

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    // Rounded-square background with a warm gradient.
    let bg = CGPath(roundedRect: CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8), cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)
    ctx.addPath(bg); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        CGColor(srgbRed: 0.98, green: 0.42, blue: 0.36, alpha: 1), CGColor(srgbRed: 0.55, green: 0.27, blue: 0.86, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    ctx.resetClip()
    // Two overlapping speech bubbles.
    func bubble(_ r: CGRect, tail: CGPoint, fill: NSColor) {
        let p = NSBezierPath(ovalIn: r)
        let t = NSBezierPath()
        t.move(to: CGPoint(x: r.midX - r.width * 0.12, y: r.minY + r.height * 0.12))
        t.line(to: tail)
        t.line(to: CGPoint(x: r.midX + r.width * 0.08, y: r.minY + r.height * 0.06))
        t.close()
        NSColor.black.setStroke()
        for path in [p, t] { path.lineWidth = s * 0.022; path.stroke() }
        fill.setFill(); p.fill(); t.fill()
    }
    bubble(CGRect(x: s * 0.17, y: s * 0.40, width: s * 0.46, height: s * 0.34), tail: CGPoint(x: s * 0.24, y: s * 0.30), fill: .white)
    bubble(CGRect(x: s * 0.40, y: s * 0.22, width: s * 0.44, height: s * 0.32), tail: CGPoint(x: s * 0.76, y: s * 0.14), fill: NSColor(white: 0.97, alpha: 1))
    let para = NSMutableParagraphStyle(); para.alignment = .center
    ("あ" as NSString).draw(in: CGRect(x: s * 0.17, y: s * 0.43, width: s * 0.46, height: s * 0.26),
        withAttributes: [.font: NSFont(name: "Hiragino Sans W7", size: s * 0.2) ?? NSFont.boldSystemFont(ofSize: s * 0.2), .foregroundColor: NSColor.black, .paragraphStyle: para])
    ("A" as NSString).draw(in: CGRect(x: s * 0.40, y: s * 0.24, width: s * 0.44, height: s * 0.26),
        withAttributes: [.font: NSFont(name: "Avenir Next Heavy", size: s * 0.2) ?? NSFont.boldSystemFont(ofSize: s * 0.2), .foregroundColor: NSColor(srgbRed: 0.45, green: 0.2, blue: 0.8, alpha: 1), .paragraphStyle: para])
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
try render(1024).write(to: root.appendingPathComponent("docs/icon.png"))
print("Wrote \(out.path)")
