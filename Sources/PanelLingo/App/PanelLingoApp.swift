import AppKit
import PanelLingoKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var openHandler: (([URL]) -> Void)?
    var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running from a plain executable (swift run) still needs a regular, focusable app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let h = openHandler { h(urls) } else { pendingURLs += urls }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PanelLingoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()
    @Bindable private var settings = AppSettings.shared

    var body: some Scene {
        Window("PanelLingo", id: "main") {
            WorkspaceView(app: app)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(settings.stored.appearance == "light" ? .light : settings.stored.appearance == "dark" ? .dark : nil)
                .onAppear {
                    delegate.openHandler = { urls in handleOpen(urls) }
                    if !delegate.pendingURLs.isEmpty { handleOpen(delegate.pendingURLs); delegate.pendingURLs = [] }
                    app.handleLaunchArguments()
                }
        }
        .defaultSize(width: 1400, height: 900)
        .commands { AppCommands(app: app) }

        Settings { SettingsView() }
    }

    func handleOpen(_ urls: [URL]) {
        if let p = urls.first(where: { $0.pathExtension == ProjectStore.fileExtension }) {
            do { try app.openProject(p) } catch { app.show(error, title: "Could not open project") }
        } else { app.importItems(urls) }
    }
}

struct AppCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Library") { if app.hasProject { app.showLibrary.toggle() } }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Add Chapters…") { app.presentAddChaptersPanel() }.keyboardShortcut("o", modifiers: [.command, .option])
            Divider()
            Button("New Empty Chapter") { app.newProject() }.keyboardShortcut("n")
            Button("Open Project…") { app.presentOpenPanel() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Open Sample Project") { app.openSample() }
            Divider()
            Button("Import Pages…") { app.presentImportPanel() }.keyboardShortcut("o")
            Button("Import from Clipboard") { app.pasteFromClipboard() }.keyboardShortcut("v", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { app.toast = "All changes are saved automatically" }.keyboardShortcut("s")
            Button("Save As…") { app.presentSaveAs() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!app.hasProject)
            Divider()
            Button("Export…") { app.showExport = true }.keyboardShortcut("e").disabled(app.pages.isEmpty)
        }
        CommandMenu("Comic") {
            Button("Translate Page") { app.translateCurrentPage() }.keyboardShortcut(.return).disabled(app.currentPage == nil)
            Button("Translate Chapter…") { app.startBatch() }.keyboardShortcut(.return, modifiers: [.command, .shift]).disabled(app.pages.isEmpty)
            Button("Detect Text") { app.detectCurrentPage() }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(app.currentPage == nil)
            Button("Run OCR on Page") { app.runPipeline(PipelineRequest(stages: [.ocr], force: true)) }.disabled(app.currentPage == nil)
            Button("Re-translate Page") { app.runPipeline(PipelineRequest(stages: [.translate, .typeset], force: true)) }.disabled(app.currentPage == nil)
            Button("Clean All Text") { app.runPipeline(PipelineRequest(stages: [.clean, .typeset], force: true)) }.disabled(app.currentPage == nil)
            Divider()
            Button("Merge Selected Regions") { app.mergeSelectedRegions() }.keyboardShortcut("m", modifiers: [.command, .shift]).disabled(app.selectedRegionIDs.count < 2)
            Button("Split Region") { app.splitSelectedRegion() }.disabled(app.selectedRegion == nil)
            Button("Edit Translation") { if let r = app.selectedRegion { app.editingRegionID = r.id } }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(app.selectedRegion == nil)
            Divider()
            Button("Reading Order Mode") { app.tool = .readingOrder }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Auto Reading Order") { if let id = app.selectedPageID { app.reorderAutomatically(id) } }
            Divider()
            Button("Glossary…") { app.showGlossary = true }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!app.hasProject)
            Button("Project Settings…") { app.showProjectSettings = true }.keyboardShortcut(",", modifiers: [.command, .option]).disabled(!app.hasProject)
            Button("Batch Progress…") { app.showBatch = true }
        }
        CommandGroup(after: .toolbar) {
            Button("Original") { app.displayMode = .original }.keyboardShortcut("1")
            Button("Cleaned") { app.displayMode = .cleaned }.keyboardShortcut("2")
            Button("Translated") { app.displayMode = .translated }.keyboardShortcut("3")
            Button("Toggle Original / Translated") { app.displayMode = app.displayMode == .original ? .translated : .original }.keyboardShortcut("`")
            Divider()
            Button("Split Compare") { app.comparison = app.comparison == .split ? .none : .split }.keyboardShortcut("\\")
            Button("Side by Side") { app.comparison = app.comparison == .sideBySide ? .none : .sideBySide }.keyboardShortcut("\\", modifiers: [.command, .shift])
            Divider()
            Button("Zoom In") { app.canvas.send(.zoomIn) }.keyboardShortcut("+")
            Button("Zoom In") { app.canvas.send(.zoomIn) }.keyboardShortcut("=")
            Button("Zoom Out") { app.canvas.send(.zoomOut) }.keyboardShortcut("-")
            Button("Fit Page") { app.canvas.send(.fitPage) }.keyboardShortcut("0")
            Button("Fit Width") { app.canvas.send(.fitWidth) }.keyboardShortcut("0", modifiers: [.command, .shift])
            Button("Actual Pixels") { app.canvas.send(.actualSize) }.keyboardShortcut("9")
            Divider()
            Button("Previous Page") { step(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next Page") { step(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }

    func step(_ d: Int) {
        guard let i = app.currentPageIndex else { return }
        let j = i + d
        if app.pages.indices.contains(j) { app.selectedPageID = app.pages[j].id }
    }
}
