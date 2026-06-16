//
//  VTraceGUIApp.swift
//  VTraceGUI
//
//  Created by Zach Gage on 6/12/26.
//

import SwiftUI

@main
struct VTraceGUIApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 520)
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
