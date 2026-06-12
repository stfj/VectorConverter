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
                Button("Open…") { model.openImagePanel() }
                    .keyboardShortcut("o")
                Button("Export SVG…") { model.exportSVG() }
                    .keyboardShortcut("s")
                    .disabled(model.svgText == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Delete Shape") { model.undoDeleteShape() }
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
