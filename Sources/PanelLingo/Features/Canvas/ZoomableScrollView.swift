import AppKit
import SwiftUI

/// Clip view that keeps a smaller-than-viewport document centred.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}


/// Native NSScrollView with pinch/trackpad magnification hosting SwiftUI content at image-pixel size.
/// Content coordinates therefore equal source-image pixel coordinates at every zoom level.
struct ZoomableScrollView: NSViewRepresentable {
    let contentSize: CGSize
    let canvas: CanvasModel
    var syncGroup: String?
    var content: AnyView

    func makeCoordinator() -> ZoomCoordinator { ZoomCoordinator(canvas: canvas, syncGroup: syncGroup) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.contentView = CenteringClipView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.allowsMagnification = true
        sv.minMagnification = 0.02
        sv.maxMagnification = 16
        sv.backgroundColor = .underPageBackgroundColor
        sv.drawsBackground = true
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: contentSize)
        sv.documentView = host
        context.coordinator.attach(sv)
        DispatchQueue.main.async { context.coordinator.fit(.fitPage) }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let host = sv.documentView as? NSHostingView<AnyView> else { return }
        host.rootView = content
        if host.frame.size != contentSize {
            host.frame = CGRect(origin: .zero, size: contentSize)
            DispatchQueue.main.async { context.coordinator.fit(.fitPage) }
        }
        if let (cmd, id) = canvas.command, id != context.coordinator.lastCommand {
            context.coordinator.lastCommand = id
            DispatchQueue.main.async { context.coordinator.fit(cmd) }
        }
    }

    static func dismantleNSView(_ sv: NSScrollView, coordinator: ZoomCoordinator) { coordinator.detach() }

}

@MainActor
final class ZoomCoordinator: NSObject {
    let canvas: CanvasModel
    let syncGroup: String?
    weak var scrollView: NSScrollView?
    var lastCommand: UUID?
    var syncing = false
    nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    static var groups: [String: [WeakScroll]] = [:]
    struct WeakScroll { weak var view: NSScrollView? }

    init(canvas: CanvasModel, syncGroup: String?) { self.canvas = canvas; self.syncGroup = syncGroup }

    func attach(_ sv: NSScrollView) {
        scrollView = sv
        sv.contentView.postsBoundsChangedNotifications = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        })
        observers.append(nc.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: sv, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        })
        sv.delegateCoordinator = self
        if let g = syncGroup { Self.groups[g, default: []].append(WeakScroll(view: sv)) }
    }

    func detach() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        if let g = syncGroup { Self.groups[g]?.removeAll { $0.view == nil || $0.view === scrollView } }
    }

    func changed() {
        guard let sv = scrollView else { return }
        if abs(canvas.magnification - sv.magnification) > 0.0001 { canvas.magnification = sv.magnification }
        guard let g = syncGroup, !syncing else { return }
        for peer in Self.groups[g] ?? [] {
            guard let other = peer.view, other !== sv,
                  let coord = (other.delegateCoordinator) else { continue }
            coord.syncing = true
            other.magnification = sv.magnification
            other.contentView.scroll(to: sv.contentView.bounds.origin)
            other.reflectScrolledClipView(other.contentView)
            coord.syncing = false
        }
    }

    func fit(_ cmd: CanvasModel.Command) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let viewport = sv.contentView.frame.size
        let size = doc.frame.size
        guard size.width > 0, size.height > 0, viewport.width > 0 else { return }
        switch cmd {
        case .fitPage: sv.magnification = min(viewport.width / size.width, viewport.height / size.height) * 0.98
        case .fitWidth:
            sv.magnification = (viewport.width - 20) / size.width
            sv.contentView.scroll(to: .zero)
        case .actualSize:
            let screen = sv.window?.backingScaleFactor ?? 2
            sv.magnification = 1 / screen
        case .zoomIn: sv.setMagnification(sv.magnification * 1.25, centeredAt: center(sv))
        case .zoomOut: sv.setMagnification(sv.magnification / 1.25, centeredAt: center(sv))
        }
        sv.reflectScrolledClipView(sv.contentView)
        changed()
    }

    func center(_ sv: NSScrollView) -> NSPoint {
        let b = sv.contentView.bounds
        return NSPoint(x: b.midX, y: b.midY)
    }
}

private var coordinatorKey: UInt8 = 0
extension NSScrollView {
    /// Associates a coordinator so synchronised peers can suppress feedback loops.
    @MainActor var delegateCoordinator: ZoomCoordinator? {
        get { objc_getAssociatedObject(self, &coordinatorKey) as? ZoomCoordinator }
        set { objc_setAssociatedObject(self, &coordinatorKey, newValue, .OBJC_ASSOCIATION_ASSIGN) }
    }
}
