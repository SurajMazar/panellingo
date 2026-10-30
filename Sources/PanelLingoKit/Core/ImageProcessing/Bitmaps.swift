import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageIOHelper {
    public static func source(_ data: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// Decodes an image applying EXIF orientation so pixel data matches what the user sees.
    public static func cgImage(from data: Data) throws -> CGImage {
        guard let src = source(data), CGImageSourceGetCount(src) > 0 else {
            throw PanelLingoError.imageDecodeFailed("unrecognised image data")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        guard let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw PanelLingoError.imageDecodeFailed("decoder returned no image")
        }
        if orientation == 1 { return img }
        // Re-render through the thumbnail API, which applies the transform at full size.
        let maxDim = max(img.width, img.height)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) ?? img
    }

    public static func cgImage(contentsOf url: URL) throws -> CGImage {
        try cgImage(from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Pixel size without decoding the bitmap.
    public static func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let src = source(data), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              var w = p[kCGImagePropertyPixelWidth] as? Int, var h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        if let o = p[kCGImagePropertyOrientation] as? UInt32, o >= 5 { swap(&w, &h) }
        return (w, h)
    }

    public static func thumbnail(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = source(data) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    public static func encode(_ image: CGImage, type: UTType, quality: Double = 0.92) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw PanelLingoError.unsupportedFile("cannot encode \(type.identifier)")
        }
        var props: [CFString: Any] = [:]
        if type == .jpeg || type == .heic { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PanelLingoError.unsupportedFile("encoding failed") }
        return data as Data
    }

    public static func png(_ image: CGImage) throws -> Data { try encode(image, type: .png) }

    public static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "tif", "tiff", "heic", "heif", "bmp", "gif", "avif"]

    public static func isImageFile(_ url: URL) -> Bool { supportedExtensions.contains(url.pathExtension.lowercased()) }

    public static func uti(forExtension ext: String) -> UTType? { UTType(filenameExtension: ext.lowercased()) }
}

// MARK: - Grayscale

/// 8-bit grayscale bitmap, row-major, top-left origin.
public struct GrayImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: width * height))
    }

    /// Renders `image` (optionally a sub-rect, optionally scaled) into a gray bitmap.
    public init(_ image: CGImage, crop: PixelRect? = nil, scale: Double = 1) {
        let r = (crop ?? PixelRect(x: 0, y: 0, width: Double(image.width), height: Double(image.height))).integral
            .clamped(width: Double(image.width), height: Double(image.height))
        let w = max(1, Int((r.width * scale).rounded())), h = max(1, Int((r.height * scale).rounded()))
        var px = [UInt8](repeating: 255, count: w * h)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = scale < 1 ? .high : .none
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // Draw the full image offset so that the crop lands at the origin (CG is bottom-left).
            let full = CGRect(x: -r.x * scale, y: -(Double(image.height) - r.maxY) * scale,
                              width: Double(image.width) * scale, height: Double(image.height) * scale)
            ctx.draw(image, in: full)
        }
        self.init(width: w, height: h, pixels: px)
    }

    @inline(__always) public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    public func cgImage() -> CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Otsu threshold over the whole bitmap.
    public func otsuThreshold() -> UInt8 {
        var hist = [Int](repeating: 0, count: 256)
        for p in pixels { hist[Int(p)] += 1 }
        let total = pixels.count
        var sum = 0.0
        for i in 0..<256 { sum += Double(i * hist[i]) }
        var sumB = 0.0, wB = 0, best = 0.0, threshold = 127
        for t in 0..<256 {
            wB += hist[t]; if wB == 0 { continue }
            let wF = total - wB; if wF == 0 { break }
            sumB += Double(t * hist[t])
            let mB = sumB / Double(wB), mF = (sum - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; threshold = t }
        }
        return UInt8(threshold)
    }

    public func threshold(below t: UInt8) -> BitMask {
        BitMask(width: width, height: height, bits: pixels.map { $0 < t ? 1 : 0 })
    }

    public func threshold(atLeast t: UInt8) -> BitMask {
        BitMask(width: width, height: height, bits: pixels.map { $0 >= t ? 1 : 0 })
    }

    public func cropped(_ r: PixelRect) -> GrayImage {
        let c = r.integral.clamped(width: Double(width), height: Double(height))
        let x0 = Int(c.x), y0 = Int(c.y), w = Int(c.width), h = Int(c.height)
        var out = [UInt8](repeating: 255, count: max(0, w * h))
        for y in 0..<h {
            let src = (y0 + y) * width + x0
            out.replaceSubrange(y * w..<(y + 1) * w, with: pixels[src..<src + w])
        }
        return GrayImage(width: w, height: h, pixels: out)
    }
}

// MARK: - Binary masks

/// Binary mask (0/1), row-major, top-left origin.
public struct BitMask: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var bits: [UInt8]

    public init(width: Int, height: Int, bits: [UInt8]) { self.width = width; self.height = height; self.bits = bits }
    public init(width: Int, height: Int) { self.init(width: width, height: height, bits: [UInt8](repeating: 0, count: width * height)) }

    @inline(__always) public subscript(x: Int, y: Int) -> Bool {
        get { bits[y * width + x] != 0 }
        set { bits[y * width + x] = newValue ? 1 : 0 }
    }

    public var count: Int { bits.reduce(0) { $0 + Int($1) } }
    public var isEmpty: Bool { !bits.contains(1) }

    public var boundingBox: PixelRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where bits[row + x] != 0 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        return maxX < 0 ? nil : PixelRect(x: Double(minX), y: Double(minY), width: Double(maxX - minX + 1), height: Double(maxY - minY + 1))
    }

    /// Separable square dilation by `radius` pixels.
    public func dilated(_ radius: Int) -> BitMask {
        guard radius > 0 else { return self }
        return morph(radius, dilate: true)
    }

    public func eroded(_ radius: Int) -> BitMask {
        guard radius > 0 else { return self }
        return morph(radius, dilate: false)
    }

    private func morph(_ r: Int, dilate: Bool) -> BitMask {
        // Row pass then column pass using running counts (O(n) per pixel row).
        var tmp = [UInt8](repeating: 0, count: bits.count)
        let target: Int = dilate ? 1 : (2 * r + 1)
        bits.withUnsafeBufferPointer { src in
            for y in 0..<height {
                let row = y * width
                var count = 0
                for x in 0..<min(r, width) { count += Int(src[row + x]) }
                for x in 0..<width {
                    if x + r < width { count += Int(src[row + x + r]) }
                    if x - r - 1 >= 0 { count -= Int(src[row + x - r - 1]) }
                    let span = min(width - 1, x + r) - max(0, x - r) + 1
                    tmp[row + x] = dilate ? (count >= target ? 1 : 0) : (count == span && span >= min(target, width) ? 1 : 0)
                }
            }
        }
        var out = [UInt8](repeating: 0, count: bits.count)
        tmp.withUnsafeBufferPointer { src in
            for x in 0..<width {
                var count = 0
                for y in 0..<min(r, height) { count += Int(src[y * width + x]) }
                for y in 0..<height {
                    if y + r < height { count += Int(src[(y + r) * width + x]) }
                    if y - r - 1 >= 0 { count -= Int(src[(y - r - 1) * width + x]) }
                    let span = min(height - 1, y + r) - max(0, y - r) + 1
                    out[y * width + x] = dilate ? (count >= 1 ? 1 : 0) : (count == span && span >= min(target, height) ? 1 : 0)
                }
            }
        }
        return BitMask(width: width, height: height, bits: out)
    }

    public static func & (a: BitMask, b: BitMask) -> BitMask {
        BitMask(width: a.width, height: a.height, bits: zip(a.bits, b.bits).map { $0 & $1 })
    }

    public static func | (a: BitMask, b: BitMask) -> BitMask {
        BitMask(width: a.width, height: a.height, bits: zip(a.bits, b.bits).map { $0 | $1 })
    }

    public var inverted: BitMask { BitMask(width: width, height: height, bits: bits.map { 1 - $0 }) }

    /// Holes: background pixels not 4-connected to the mask border.
    public func filledHoles() -> BitMask {
        var reach = [UInt8](repeating: 0, count: bits.count)
        var stack: [Int] = []
        func push(_ i: Int) { if bits[i] == 0 && reach[i] == 0 { reach[i] = 1; stack.append(i) } }
        for x in 0..<width { push(x); push((height - 1) * width + x) }
        for y in 0..<height { push(y * width); push(y * width + width - 1) }
        while let i = stack.popLast() {
            let x = i % width, y = i / width
            if x > 0 { push(i - 1) }; if x < width - 1 { push(i + 1) }
            if y > 0 { push(i - width) }; if y < height - 1 { push(i + width) }
        }
        return BitMask(width: width, height: height, bits: reach.map { 1 - $0 })
    }

    /// Mask → 8-bit gray image (255 = set).
    public func grayImage() -> GrayImage {
        GrayImage(width: width, height: height, pixels: bits.map { $0 == 0 ? 0 : 255 })
    }

    public init(gray: GrayImage, threshold: UInt8 = 128) {
        self.init(width: gray.width, height: gray.height, bits: gray.pixels.map { $0 >= threshold ? 1 : 0 })
    }

    public func cropped(_ r: PixelRect) -> BitMask {
        let g = GrayImage(width: width, height: height, pixels: bits).cropped(r)
        return BitMask(width: g.width, height: g.height, bits: g.pixels.map { $0 == 255 ? 0 : $0 })
    }

    /// Outer contour (Moore neighbourhood tracing) of the largest blob, in mask pixel coordinates.
    public func outerContour() -> [PixelPoint] {
        guard let start = bits.firstIndex(of: 1) else { return [] }
        let sx = start % width, sy = start / width
        let dirs = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
        func at(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height && bits[y * width + x] != 0 }
        var pts: [PixelPoint] = [PixelPoint(x: Double(sx), y: Double(sy))]
        var cx = sx, cy = sy, dir = 7
        let limit = 4 * (width + height) * 4
        for _ in 0..<limit {
            var found = false
            for k in 0..<8 {
                let d = (dir + 6 + k) % 8
                let nx = cx + dirs[d].0, ny = cy + dirs[d].1
                if at(nx, ny) { cx = nx; cy = ny; dir = d; found = true; break }
            }
            if !found || (cx == sx && cy == sy) { break }
            pts.append(PixelPoint(x: Double(cx), y: Double(cy)))
        }
        return pts
    }
}

// MARK: - Connected components

public struct Component: Sendable {
    public var label: Int32
    public var area: Int
    public var minX: Int, minY: Int, maxX: Int, maxY: Int
    public var touchesBorder: Bool
    public var width: Int { maxX - minX + 1 }
    public var height: Int { maxY - minY + 1 }
    public var rect: PixelRect { PixelRect(x: Double(minX), y: Double(minY), width: Double(width), height: Double(height)) }
    public var fillRatio: Double { Double(area) / Double(width * height) }
}

public struct ComponentLabels: Sendable {
    public var width: Int
    public var height: Int
    /// 0 = background; component `i` has label `i + 1`.
    public var labels: [Int32]
    public var components: [Component]

    /// Two-pass-free stack flood labeling (4-connectivity) of set pixels in `mask`.
    public init(_ mask: BitMask, eightConnected: Bool = false) {
        width = mask.width; height = mask.height
        labels = [Int32](repeating: 0, count: mask.bits.count)
        components = []
        var stack: [Int] = []
        stack.reserveCapacity(4096)
        let w = width, h = height
        mask.bits.withUnsafeBufferPointer { bits in
            labels.withUnsafeMutableBufferPointer { lab in
                for start in 0..<bits.count where bits[start] != 0 && lab[start] == 0 {
                    let l = Int32(components.count + 1)
                    var c = Component(label: l, area: 0, minX: w, minY: h, maxX: 0, maxY: 0, touchesBorder: false)
                    lab[start] = l
                    stack.append(start)
                    while let i = stack.popLast() {
                        let x = i % w, y = i / w
                        c.area += 1
                        if x < c.minX { c.minX = x }; if x > c.maxX { c.maxX = x }
                        if y < c.minY { c.minY = y }; if y > c.maxY { c.maxY = y }
                        if x == 0 || y == 0 || x == w - 1 || y == h - 1 { c.touchesBorder = true }
                        @inline(__always) func visit(_ j: Int) {
                            if bits[j] != 0 && lab[j] == 0 { lab[j] = l; stack.append(j) }
                        }
                        if x > 0 { visit(i - 1) }
                        if x < w - 1 { visit(i + 1) }
                        if y > 0 { visit(i - w) }
                        if y < h - 1 { visit(i + w) }
                        if eightConnected {
                            if x > 0 && y > 0 { visit(i - w - 1) }
                            if x < w - 1 && y > 0 { visit(i - w + 1) }
                            if x > 0 && y < h - 1 { visit(i + w - 1) }
                            if x < w - 1 && y < h - 1 { visit(i + w + 1) }
                        }
                    }
                    components.append(c)
                }
            }
        }
    }

    /// Mask of one component cropped to its bounding box (optionally padded).
    public func mask(of c: Component, padding: Int = 0) -> (BitMask, originX: Int, originY: Int) {
        let x0 = max(0, c.minX - padding), y0 = max(0, c.minY - padding)
        let x1 = min(width - 1, c.maxX + padding), y1 = min(height - 1, c.maxY + padding)
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        var m = BitMask(width: w, height: h)
        for y in 0..<h {
            let row = (y0 + y) * width
            for x in 0..<w where labels[row + x0 + x] == c.label { m.bits[y * w + x] = 1 }
        }
        return (m, x0, y0)
    }
}

// MARK: - RGBA

/// 8-bit RGBA (premultiplied last) bitmap in sRGB, row-major, top-left origin.
public struct RGBAImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) { self.width = width; self.height = height; self.pixels = pixels }

    public init(width: Int, height: Int) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 4))
    }

    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Extracts `crop` (source pixels) from `image` without resampling.
    public init(_ image: CGImage, crop: PixelRect? = nil) {
        let r = (crop ?? PixelRect(x: 0, y: 0, width: Double(image.width), height: Double(image.height))).integral
            .clamped(width: Double(image.width), height: Double(image.height))
        let w = max(1, Int(r.width)), h = max(1, Int(r.height))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: RGBAImage.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: -r.x, y: -(Double(image.height) - r.maxY), width: Double(image.width), height: Double(image.height)))
        }
        self.init(width: w, height: h, pixels: px)
    }

    public func cgImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: RGBAImage.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public func gray() -> GrayImage {
        var g = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Int(pixels[i * 4]), gg = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
            g[i] = UInt8((r * 299 + gg * 587 + b * 114) / 1000)
        }
        return GrayImage(width: width, height: height, pixels: g)
    }
}

public enum ImageCompose {
    /// Bitmap context in the colour space best matching `image`, so unchanged pixels round-trip exactly.
    public static func context(for image: CGImage) -> CGContext? {
        let space: CGColorSpace
        if let cs = image.colorSpace, cs.model == .rgb { space = cs } else { space = RGBAImage.colorSpace }
        return CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    public static func flipToTopLeft(_ ctx: CGContext, height: Int) {
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
    }
}
