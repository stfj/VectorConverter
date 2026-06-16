//
//  VTraceGUIApp.swift
//  VTraceGUI
//
//  Created by Zach Gage on 6/12/26.
//

import SwiftUI

@main
struct VTraceGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // A single `Window` (not `WindowGroup`): opening a .vtrace from Finder
        // can't spawn a second window — the delegate just loads the file into
        // this one window's model.
        Window("VTraceGUI", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear {
                    // Finder double-clicks / "Open With" arrive via the app
                    // delegate; route any (including one buffered before the
                    // window existed) into the model.
                    appDelegate.registerOpenHandler { url in
                        model.loadDesign(from: url)
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Image…") { model.openImagePanel() }
                    .keyboardShortcut("o")
                Button("Open Design…") { model.openDesignPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Design…") { model.saveDesign() }
                    .keyboardShortcut("s")
                    .disabled(!model.canSaveDesign)
                Button("Save Design As…") { model.saveDesignAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.canSaveDesign)
                Divider()
                Button("Export SVG…") { model.exportSVG() }
                    .keyboardShortcut("e")
                    .disabled(model.svgText == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undoLastEdit() }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndoDeletion)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Copy SVG") { model.copySVGToClipboard() }
                    .keyboardShortcut("c")
                    .disabled(model.svgText == nil)
                Button("Paste Image") { model.pasteFromClipboard() }
                    .keyboardShortcut("v")
            }
        }
    }
}

/// Receives Finder document-open events (double-click, "Open With", `open`)
/// for `.vtrace` files and forwards them to the window's model. URLs that
/// arrive during a cold launch — before any window's `onAppear` registers a
/// handler — are buffered and drained on registration.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openHandler: ((URL) -> Void)?
    private var pendingURLs: [URL] = []

    func registerOpenHandler(_ handler: @escaping (URL) -> Void) {
        openHandler = handler
        for url in pendingURLs { handler(url) }
        pendingURLs.removeAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let openHandler else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls { openHandler(url) }
    }
}
