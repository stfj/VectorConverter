//
//  ContentView.swift
//  VTraceGUI
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        HSplitView {
            previewArea
                .frame(minWidth: 480, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
            ControlsView(model: model)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.openImagePanel()
                } label: {
                    Label("Open…", systemImage: "folder")
                }
                .help("Open an image (⌘O)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.exportSVG()
                } label: {
                    Label("Export SVG…", systemImage: "square.and.arrow.down")
                }
                .disabled(model.svgText == nil)
                .help("Export the traced SVG (⌘S)")
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var previewArea: some View {
        ZStack {
            if model.imageVersion == 0 {
                emptyState
            } else {
                SVGPreviewView(model: model)
            }

            if model.isConverting {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            }

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
            }
        }
        .overlay(alignment: .bottom) {
            if model.imageVersion > 0 || model.errorMessage != nil {
                statusBar
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.arrow.down")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Drag an image here")
                .font(.title3.weight(.medium))
            Text("paste with ⌘V, or")
                .foregroundStyle(.secondary)
            Button("Choose Image…") {
                model.openImagePanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(.quaternary)
                .padding(20)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            if let size = model.sourcePixelSize {
                Text("\(Int(size.width)) × \(Int(size.height)) px")
            }
            if model.pathCount > 0 {
                Text("\(model.pathCount) paths")
            }
            if let raw = model.rawPointCount, let out = model.pointCount, raw > 0 {
                if raw != out {
                    Text("\(raw.formatted()) → \(out.formatted()) points")
                } else {
                    Text("\(out.formatted()) points")
                }
            }
            if let nodes = model.nodeCount, nodes > 0 {
                Text("\(nodes.formatted()) nodes")
            }
            if let seconds = model.lastConversionTime {
                Text(String(format: "%.2fs", seconds))
            }
            if let index = model.selectedPathIndex {
                Text("shape \(index + 1) selected")
                    .foregroundStyle(Color.accentColor)
            }
            if model.previewTool == .zoom {
                Text("zoom tool — click to zoom, ⌥-click out, V for cursor")
                    .foregroundStyle(Color.accentColor)
            }
            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.loadImage(from: url) }
            }
            return true
        }
        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in model.loadImage(data: data) }
            }
            return true
        }
        return false
    }
}

#Preview {
    ContentView(model: AppModel())
}
