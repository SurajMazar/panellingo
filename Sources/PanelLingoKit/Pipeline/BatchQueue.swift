import Foundation

/// Chapter processing queue: bounded concurrency, pause / resume / cancel, retry failed pages.
///
/// A failing page never stops the batch. Progress is persisted by the pipeline after every
/// stage, so completed work survives cancellation and app restarts.
public actor BatchQueue {
    public enum ItemState: Sendable, Equatable {
        case pending, running(PageStatus), done, needsReview, failed(String), skipped, cancelled
        public var isFinished: Bool {
            switch self { case .done, .needsReview, .failed, .skipped, .cancelled: true; default: false }
        }
    }

    public struct Snapshot: Sendable {
        public var order: [String]
        public var states: [String: ItemState]
        public var isRunning: Bool
        public var isPaused: Bool
        public var finished: Int { states.values.filter(\.isFinished).count }
        public var failed: Int { states.values.filter { if case .failed = $0 { return true }; return false }.count }
        public var progress: Double { order.isEmpty ? 0 : Double(finished) / Double(order.count) }
    }

    let engine: PipelineEngine
    var options: PipelineOptions
    var request: PipelineRequest
    let concurrency: Int
    let onPage: @Sendable (ComicPage) -> Void
    let onSnapshot: @Sendable (Snapshot) -> Void

    var order: [String] = []
    var states: [String: ItemState] = [:]
    var paused = false
    var running = false
    var workers: [Task<Void, Never>] = []

    public init(engine: PipelineEngine, options: PipelineOptions, request: PipelineRequest = .full, concurrency: Int,
                onPage: @escaping @Sendable (ComicPage) -> Void, onSnapshot: @escaping @Sendable (Snapshot) -> Void) {
        self.engine = engine; self.options = options; self.request = request
        self.concurrency = max(1, concurrency); self.onPage = onPage; self.onSnapshot = onSnapshot
    }

    public var snapshot: Snapshot { Snapshot(order: order, states: states, isRunning: running, isPaused: paused) }

    public func start(pageIDs: [String]) {
        order = pageIDs
        for id in pageIDs { states[id] = .pending }
        paused = false
        launch()
    }

    public func pause() { paused = true; publish() }

    public func resume() {
        paused = false
        launch()
    }

    public func cancel() {
        for w in workers { w.cancel() }
        workers.removeAll()
        for id in order where !(states[id]?.isFinished ?? true) { states[id] = .cancelled }
        running = false
        publish()
    }

    public func retryFailed() {
        for id in order {
            switch states[id] {
            case .failed, .cancelled: states[id] = .pending
            default: break
            }
        }
        paused = false
        launch()
    }

    func publish() { onSnapshot(snapshot) }

    func launch() {
        workers.removeAll { $0.isCancelled }
        running = true
        publish()
        let n = concurrency
        for _ in 0..<n {
            workers.append(Task { await self.workerLoop() })
        }
    }

    func next() -> String? {
        guard !paused else { return nil }
        guard let id = order.first(where: { states[$0] == .pending }) else { return nil }
        states[id] = .running(.pending)
        return id
    }

    func workerLoop() async {
        while !Task.isCancelled, let id = next() {
            publish()
            await process(id)
        }
        if !states.values.contains(where: { if case .running = $0 { return true }; return false }) {
            running = false
            publish()
        }
    }

    func process(_ id: String) async {
        guard let page = engine.store.loadPage(id) else { states[id] = .failed("page missing"); return }
        if !request.force && page.status == .completed && PipelineStage.allCases.allSatisfy({ page.completedStages.contains($0) }) {
            states[id] = .skipped; publish(); return
        }
        do {
            let result = try await engine.run(page, request: request, options: options) { [weak self] p in
                self?.onPage(p)
                Task { await self?.setRunning(p.id, p.status) }
            }
            states[id] = result.status == .needsReview ? .needsReview : .done
        } catch PanelLingoError.cancelled {
            states[id] = .cancelled
        } catch {
            states[id] = .failed(error.localizedDescription)
        }
        publish()
    }

    func setRunning(_ id: String, _ s: PageStatus) {
        if case .running = states[id] { states[id] = .running(s); publish() }
    }
}
