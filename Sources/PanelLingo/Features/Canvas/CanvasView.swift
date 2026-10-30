import AppKit
import PanelLingoKit
import SwiftUI

/// Centre workspace: single, split-compare or synchronised side-by-side canvases.
struct CanvasArea: View {
    @Bindable var app: AppState

    var body: some View {
        Group {
            if let page = app.currentPage, let original = app.originalImage {
                let size = CGSize(width: original.width, height: original.height)
                switch app.comparison {
                case .sideBySide:
                    HStack(spacing: 1) {
                        labelled("Original") {
                            ZoomableScrollView(contentSize: size, canvas: app.canvas, syncGroup: "compare",
                                               content: AnyView(PageCanvasContent(app: app, page: page, mode: .original, interactive: false)))
                        }
                        labelled(app.displayMode == .original ? "Translated" : app.displayMode.displayName) {
                            ZoomableScrollView(contentSize: size, canvas: app.canvas, syncGroup: "compare",
                                               content: AnyView(PageCanvasContent(app: app, page: page,
                                                                                  mode: app.displayMode == .original ? .translated : app.displayMode,
                                                                                  interactive: true)))
                        }
                    }
                default:
                    ZoomableScrollView(contentSize: size, canvas: app.canvas,
                                       content: AnyView(PageCanvasContent(app: app, page: page, mode: app.displayMode, interactive: true)))
                }
            } else if app.hasProject {
                DropTargetPlaceholder(app: app, title: app.pages.isEmpty ? "Drop comic pages here" : "Select a page",
                                      subtitle: "Images, PDF, CBZ / CBR archives or folders")
            } else {
                WelcomeView(app: app)
            }
        }
        .overlay(alignment: .bottom) { CanvasStatusBar(app: app) }
    }

    func labelled<V: View>(_ title: String, @ViewBuilder _ v: () -> V) -> some View {
        v().overlay(alignment: .top) {
            Text(title).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                .background(.thinMaterial, in: Capsule()).padding(.top, 8)
        }
    }
}

/// Image + overlays at source-pixel size. Everything inside uses image pixel coordinates.
struct PageCanvasContent: View {
    @Bindable var app: AppState
    let page: ComicPage
    let mode: RenderMode
    let interactive: Bool

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var polygon: [CGPoint] = []
    @State private var stroke: [CGPoint] = []

    var mag: Double { max(0.02, app.canvas.magnification) }
    var lw: Double { 1.5 / mag }

    var body: some View {
        let w = Double(page.pixelWidth), h = Double(page.pixelHeight)
        ZStack(alignment: .topLeading) {
            if let img = app.image(for: mode) {
                Image(decorative: img, scale: 1).resizable().interpolation(mag >= 1 ? .none : .high)
                    .frame(width: w, height: h)
            }
            if app.comparison == .split && interactive, let orig = app.originalImage {
                SplitCompareLayer(app: app, original: orig, width: w, height: h, lineWidth: lw)
            }
            if interactive && app.showOverlays && mode != .original || interactive && app.tool != .select {
                overlays
            }
            if interactive && app.tool != .select && app.tool != .readingOrder { toolLayer(w: w, h: h) }
            if interactive, let id = app.editingRegionID, let r = page.regions.first(where: { $0.id == id }) {
                InlineTranslationEditor(app: app, region: r, scale: 1 / mag)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { if app.tool == .select { app.selectedRegionIDs = []; app.editingRegionID = nil } }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in loadDrop(providers, app: app); return true }
    }

    // MARK: Overlays

    @ViewBuilder var overlays: some View {
        ForEach(page.panels, id: \.index) { p in
            if app.tool == .readingOrder {
                Rectangle().stroke(Color.purple.opacity(0.45), style: StrokeStyle(lineWidth: lw * 1.5, dash: [8 / mag, 6 / mag]))
                    .frame(width: p.bbox.width, height: p.bbox.height).offset(x: p.bbox.x, y: p.bbox.y)
                    .allowsHitTesting(false)
            }
        }
        if (app.tool == .brush || app.tool == .eraser || mode == .cleaned), let r = app.selectedRegion,
           let tint = MaskTintCache.shared.image(app: app, page: page, region: r), let rect = r.cleanup.maskRect {
            Image(decorative: tint, scale: 1).resizable().frame(width: rect.width, height: rect.height)
                .offset(x: rect.x, y: rect.y).allowsHitTesting(false)
        }
        ForEach(page.orderedRegions) { r in
            RegionOverlay(app: app, region: r, lineWidth: lw, magnification: mag)
        }
    }

    // MARK: Drawing tools

    func toolLayer(w: Double, h: Double) -> some View {
        Rectangle().fill(Color.white.opacity(0.001))
            .frame(width: w, height: h)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in
                    switch app.tool {
                    case .rectangle: if dragStart == nil { dragStart = v.startLocation }; dragCurrent = v.location
                    case .brush, .eraser:
                        if stroke.isEmpty, app.selectedRegion == nil, let hit = page.orderedRegions.last(where: { $0.bbox.contains(PixelPoint(x: v.startLocation.x, y: v.startLocation.y)) }) {
                            app.selectedRegionIDs = [hit.id]
                        }
                        stroke.append(v.location)
                    default: break
                    }
                }
                .onEnded { v in
                    switch app.tool {
                    case .rectangle:
                        if let s = dragStart {
                            let r = CGRect(x: min(s.x, v.location.x), y: min(s.y, v.location.y), width: abs(v.location.x - s.x), height: abs(v.location.y - s.y))
                            app.addRegion(bbox: PixelRect(r).clamped(width: w, height: h))
                        }
                        dragStart = nil; dragCurrent = nil
                    case .polygon:
                        let p = v.location
                        if let first = polygon.first, polygon.count >= 3, hypot(first.x - p.x, first.y - p.y) < 12 / mag {
                            finishPolygon(w: w, h: h)
                        } else { polygon.append(p) }
                    case .brush, .eraser:
                        if let r = app.selectedRegion, !stroke.isEmpty {
                            app.paintMask(regionID: r.id, points: stroke.map { PixelPoint(x: $0.x, y: $0.y) }, erase: app.tool == .eraser)
                        } else if app.selectedRegion == nil { app.toast = "Select a region before painting its mask" }
                        stroke = []
                    default: break
                    }
                })
            .overlay(alignment: .topLeading) { toolPreview }
            .onKeyPress(.return) { finishPolygon(w: w, h: h); return .handled }
            .onKeyPress(.escape) { polygon = []; dragStart = nil; app.tool = .select; return .handled }
    }

    func finishPolygon(w: Double, h: Double) {
        guard polygon.count >= 3 else { polygon = []; return }
        let pts = polygon.map { PixelPoint(x: $0.x, y: $0.y) }
        app.addRegion(bbox: PolygonMath.boundingRect(pts).clamped(width: w, height: h), polygon: pts)
        polygon = []
    }

    @ViewBuilder var toolPreview: some View {
        if let s = dragStart, let c = dragCurrent {
            Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: lw * 1.5, dash: [6 / mag, 4 / mag]))
                .frame(width: abs(c.x - s.x), height: abs(c.y - s.y)).offset(x: min(s.x, c.x), y: min(s.y, c.y))
                .allowsHitTesting(false)
        }
        if !polygon.isEmpty {
            Path { p in p.addLines(polygon) }.stroke(Color.accentColor, lineWidth: lw * 1.5).allowsHitTesting(false)
            ForEach(Array(polygon.enumerated()), id: \.offset) { i, pt in
                Circle().fill(i == 0 ? Color.green : Color.accentColor).frame(width: 8 / mag, height: 8 / mag)
                    .offset(x: pt.x - 4 / mag, y: pt.y - 4 / mag).allowsHitTesting(false)
            }
        }
        if !stroke.isEmpty {
            Path { p in p.addLines(stroke) }
                .stroke(app.tool == .eraser ? Color.blue.opacity(0.5) : Color.red.opacity(0.5),
                        style: StrokeStyle(lineWidth: app.brushSize, lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)
        }
    }
}

/// One region's outline, number badge, selection handles and gestures.
struct RegionOverlay: View {
    @Bindable var app: AppState
    let region: TextRegion
    let lineWidth: Double
    let magnification: Double
    @State private var moveOffset: CGSize = .zero
    @State private var resizeRect: PixelRect?

    var selected: Bool { app.selectedRegionIDs.contains(region.id) }
    var color: Color {
        if region.review == .needsReview { return .orange }
        if region.doNotTranslate { return .gray }
        if region.locked { return .purple }
        switch region.kind {
        case .sfx: return .pink
        case .caption, .dialogueBox: return .teal
        case .freeText, .artText: return .yellow
        default: return .blue
        }
    }

    var body: some View {
        let rect = resizeRect ?? region.bbox
        ZStack(alignment: .topLeading) {
            shape(rect)
            badge.offset(x: rect.x - 10 / magnification, y: rect.y - 10 / magnification)
            if selected && app.tool == .select && !region.locked { handles(rect) }
        }
        .offset(moveOffset)
    }

    @ViewBuilder func shape(_ rect: PixelRect) -> some View {
        let base = Rectangle()
            .stroke(color.opacity(selected ? 1 : 0.75), style: StrokeStyle(lineWidth: lineWidth * (selected ? 2 : 1), dash: region.isManual ? [6 / magnification, 3 / magnification] : []))
            .background(color.opacity(selected ? 0.12 : 0.04))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.x, y: rect.y)
        if let poly = region.polygon, selected {
            Path { p in p.addLines(poly.map(\.cgPoint)); p.closeSubpath() }
                .stroke(color.opacity(0.6), style: StrokeStyle(lineWidth: lineWidth, dash: [4 / magnification, 3 / magnification]))
                .allowsHitTesting(false)
        }
        base
            .contentShape(Rectangle().offset(x: rect.x, y: rect.y).size(width: rect.width, height: rect.height))
            .onTapGesture(count: 2) {
                guard app.tool == .select else { return }
                app.selectedRegionIDs = [region.id]
                app.editingRegionID = region.id
            }
            .onTapGesture {
                switch app.tool {
                case .readingOrder: app.readingOrderClick(region.id)
                case .select:
                    if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                        if selected { app.selectedRegionIDs.remove(region.id) } else { app.selectedRegionIDs.insert(region.id) }
                    } else { app.selectedRegionIDs = [region.id] }
                default: break
                }
            }
            .gesture(app.tool == .select && !region.locked ? DragGesture(minimumDistance: 3 / magnification)
                .onChanged { v in
                    if !selected { app.selectedRegionIDs = [region.id] }
                    moveOffset = v.translation
                }
                .onEnded { v in
                    let dx = v.translation.width, dy = v.translation.height
                    moveOffset = .zero
                    app.updateRegion(region.id, "Move Region") { r in
                        r.bbox = r.bbox.offsetBy(dx: dx, dy: dy)
                        r.polygon = r.polygon?.map { PixelPoint(x: $0.x + dx, y: $0.y + dy) }
                        r.textArea = r.textArea?.offsetBy(dx: dx, dy: dy)
                        r.textLines = r.textLines.map { TextLine(bbox: $0.bbox.offsetBy(dx: dx, dy: dy), text: $0.text, confidence: $0.confidence) }
                    }
                } : nil)
            .contextMenu { RegionContextMenu(app: app, region: region) }
            .help(region.translatedText ?? region.sourceText)
            .accessibilityElement()
            .accessibilityLabel("\(region.kind.displayName) \(region.readingIndex + 1)")
            .accessibilityValue(region.translatedText ?? region.sourceText)
    }

    var badge: some View {
        let showNumber = app.tool == .readingOrder || selected
        return ZStack {
            Circle().fill(app.tool == .readingOrder && app.readingOrderSequence.contains(region.id) ? Color.green : color)
            if showNumber {
                Text("\(region.readingIndex + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            } else if region.review == .needsReview {
                Image(systemName: "exclamationmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: 20, height: 20)
        .scaleEffect(1 / magnification, anchor: .topLeading)
        .allowsHitTesting(app.tool == .readingOrder)
        .onTapGesture { if app.tool == .readingOrder { app.readingOrderClick(region.id) } }
    }

    @ViewBuilder func handles(_ rect: PixelRect) -> some View {
        let s = 9 / magnification
        ForEach(0..<4, id: \.self) { corner in
            let x = corner % 2 == 0 ? rect.minX : rect.maxX
            let y = corner < 2 ? rect.minY : rect.maxY
            Rectangle().fill(Color.white).overlay(Rectangle().stroke(color, lineWidth: lineWidth))
                .frame(width: s, height: s).offset(x: x - s / 2, y: y - s / 2)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        var minX = region.bbox.minX, minY = region.bbox.minY, maxX = region.bbox.maxX, maxY = region.bbox.maxY
                        if corner % 2 == 0 { minX = min(maxX - 4, minX + v.translation.width) } else { maxX = max(minX + 4, maxX + v.translation.width) }
                        if corner < 2 { minY = min(maxY - 4, minY + v.translation.height) } else { maxY = max(minY + 4, maxY + v.translation.height) }
                        resizeRect = PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                    }
                    .onEnded { _ in
                        if let r = resizeRect { app.updateRegion(region.id, "Resize Region") { $0.bbox = r; $0.polygon = nil } }
                        resizeRect = nil
                    })
                .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
        }
    }
}

struct RegionContextMenu: View {
    let app: AppState
    let region: TextRegion
    var body: some View {
        Button("Edit Translation") { app.selectedRegionIDs = [region.id]; app.editingRegionID = region.id }
        Button("Re-translate") { app.retranslate([region.id]) }
        Button("Re-run OCR") { app.rerunOCR([region.id]) }
        Button("Clean Text") { app.clean([region.id]) }
        Button("Restore Original") { app.restoreOriginal([region.id]) }
        Divider()
        Menu("Region Type") {
            ForEach(RegionKind.allCases) { k in Button(k.displayName) { app.updateRegion(region.id, "Change Region Type") { $0.kind = k } } }
        }
        Button(region.doNotTranslate ? "Allow Translation" : "Do Not Translate") {
            app.updateRegion(region.id, "Toggle Do Not Translate") { $0.doNotTranslate.toggle() }
        }
        Button(region.locked ? "Unlock Region" : "Lock Region") { app.updateRegion(region.id, "Toggle Lock") { $0.locked.toggle() } }
        Divider()
        Button("Split Region") { app.selectedRegionIDs = [region.id]; app.splitSelectedRegion() }
        if app.selectedRegionIDs.count > 1 { Button("Merge Selected Regions") { app.mergeSelectedRegions() } }
        Button("Delete Region", role: .destructive) {
            if !app.selectedRegionIDs.contains(region.id) { app.selectedRegionIDs = [region.id] }
            app.deleteSelectedRegions()
        }
    }
}

/// Draggable before/after divider: original artwork to the left of the handle.
struct SplitCompareLayer: View {
    @Bindable var app: AppState
    let original: CGImage
    let width: Double, height: Double, lineWidth: Double

    var body: some View {
        let x = app.canvas.splitPosition * width
        ZStack(alignment: .topLeading) {
            Image(decorative: original, scale: 1).resizable().frame(width: width, height: height)
                .mask(alignment: .topLeading) { Rectangle().frame(width: x, height: height) }
                .allowsHitTesting(false)
            Rectangle().fill(Color.white).frame(width: lineWidth * 2, height: height).offset(x: x - lineWidth)
                .shadow(radius: lineWidth * 2)
            Circle().fill(.white).frame(width: 34 * lineWidth, height: 34 * lineWidth)
                .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 16 * lineWidth, weight: .bold)).foregroundStyle(.black))
                .offset(x: x - 17 * lineWidth, y: height / 2 - 17 * lineWidth)
                .gesture(DragGesture().onChanged { v in app.canvas.splitPosition = min(1, max(0, v.location.x / width)) })
                .accessibilityLabel("Comparison divider")
        }
    }
}

/// Floating editor attached to a bubble; the lettering underneath re-renders live.
struct InlineTranslationEditor: View {
    @Bindable var app: AppState
    let region: TextRegion
    let scale: Double
    @State private var text = ""
    @State private var snapshot: ComicPage?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(region.sourceText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 280, height: 90)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: text) { _, t in liveUpdate(t) }
            HStack {
                if region.layout.overflow { Label("Overflow", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                Button("Done") { commit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
        .scaleEffect(scale, anchor: .topLeading)
        .offset(x: region.bbox.x, y: region.bbox.maxY + 6 * scale)
        .onAppear {
            text = region.translatedText ?? ""
            snapshot = app.currentPage
            focused = true
        }
    }

    func liveUpdate(_ t: String) {
        guard let i = app.currentPageIndex, let ri = app.pages[i].regionIndex(region.id) else { return }
        var r = app.pages[i].regions[ri]
        if r.translation == nil {
            r.translation = TranslationRecord(text: t, provider: "manual", model: nil, modelConfidence: nil, reviewRequired: false, notes: nil, sourceText: r.sourceText)
        } else { r.translation?.text = t }
        app.pages[i].regions[ri] = r
        app.scheduleRender()
    }

    func commit() {
        guard let snap = snapshot, let page = app.currentPage else { app.editingRegionID = nil; return }
        // Restore the pre-edit page, then apply the whole edit as one undoable step.
        if let i = app.currentPageIndex { app.pages[i] = snap }
        let final = page.regions.first { $0.id == region.id }?.translation
        app.updateRegion(region.id, "Edit Translation") { r in
            r.translation = final
            r.translation?.provider = final?.provider ?? "manual"
            r.translationLocked = true
            if r.cleanup.status == .none && r.kind.isEnclosed { r.reviewReasons.removeAll { $0.hasPrefix("Translation") } }
        }
        if region.cleanup.status == .none && !(final?.text.isEmpty ?? true) { app.clean([region.id]) }
        app.editingRegionID = nil
    }

    func cancel() {
        if let snap = snapshot, let i = app.currentPageIndex { app.pages[i] = snap; app.scheduleRender() }
        app.editingRegionID = nil
    }
}

/// Caches red/blue tinted mask previews keyed by mask revision.
@MainActor
final class MaskTintCache {
    static let shared = MaskTintCache()
    private var cache: [String: CGImage] = [:]

    func image(app: AppState, page: ComicPage, region: TextRegion) -> CGImage? {
        let key = "\(page.id)/\(region.id)/\(region.cleanup.maskRevision)"
        if let c = cache[key] { return c }
        guard let mask = app.store?.loadMask(pageID: page.id, regionID: region.id) else { return nil }
        var rgba = RGBAImage(width: mask.width, height: mask.height)
        for i in 0..<mask.bits.count where mask.bits[i] != 0 {
            // Premultiplied red at ~43% opacity.
            rgba.pixels[i * 4] = 99; rgba.pixels[i * 4 + 1] = 13; rgba.pixels[i * 4 + 2] = 26; rgba.pixels[i * 4 + 3] = 110
        }
        let img = rgba.cgImage()
        if cache.count > 64 { cache.removeAll() }
        cache[key] = img
        return img
    }
}

struct CanvasStatusBar: View {
    @Bindable var app: AppState
    var body: some View {
        HStack(spacing: 10) {
            if let p = app.currentPage {
                if let task = app.pageTasks[p.id], !task.isCancelled {
                    ProgressView().controlSize(.small)
                    Text(p.status.displayName + "…").font(.callout)
                    Button("Cancel") { app.cancelProcessing(p.id) }.controlSize(.small)
                } else if let e = p.lastError {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    Text("\(e.stage.displayName) failed: \(e.message)").font(.callout).lineLimit(1)
                    Button("Retry") { app.runPipeline(PipelineRequest(stages: PipelineStage.allCases.filter { $0 >= e.stage })) }.controlSize(.small)
                } else {
                    Text("\(p.pixelWidth) × \(p.pixelHeight) px · \(p.regions.count) regions").font(.callout).foregroundStyle(.secondary)
                    if p.needsReviewCount > 0 { Label("\(p.needsReviewCount) to review", systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange) }
                }
                Divider().frame(height: 14)
                Text("\(Int(app.canvas.magnification * 100 * (NSScreen.main?.backingScaleFactor ?? 2)))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .help("Zoom (100% = actual pixels)")
            }
            if let (progress, name) = app.importProgress {
                ProgressView(value: progress).frame(width: 120)
                Text("Importing \(name)").font(.callout).lineLimit(1)
            }
            if let t = app.toast {
                Text(t).font(.callout).lineLimit(2)
                    .task(id: t) { try? await Task.sleep(nanoseconds: 3_500_000_000); if app.toast == t { app.toast = nil } }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(10)
        .opacity(app.currentPage == nil && app.importProgress == nil && app.toast == nil ? 0 : 1)
    }
}

func loadDrop(_ providers: [NSItemProvider], app: AppState) {
    var urls: [URL] = []
    let group = DispatchGroup()
    let lock = NSLock()
    for p in providers where p.hasItemConformingToTypeIdentifier("public.file-url") {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        guard !urls.isEmpty else { return }
        MainActor.assumeIsolated {
            if urls.count == 1, urls[0].pathExtension == ProjectStore.fileExtension {
                do { try app.openProject(urls[0]) } catch { app.show(error, title: "Could not open project") }
            } else { app.importItems(urls) }
        }
    }
}
