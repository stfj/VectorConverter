//
//  ToolPaletteView.swift
//  VTraceGUI
//
//  Compact, Photoshop-style two-column tool palette.
//

import SwiftUI

struct ToolPaletteView: View {
    @Bindable var model: AppModel
    @State private var hoveredTool: ToolTooltip?
    @State private var visibleTooltip: ToolTooltip?

    private let columns = [
        GridItem(.fixed(28), spacing: 4),
        GridItem(.fixed(28), spacing: 4),
    ]

    var body: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: columns, spacing: 4) {
                toolButton(.cursor, label: "Cursor", shortcut: "V",
                           symbol: "cursorarrow")
                toolButton(.anchor, label: "Edit Points", shortcut: "A",
                           symbol: "point.topleft.down.to.point.bottomright.curvepath")
                toolButton(.wand, label: "Magic Wand", shortcut: "W",
                           symbol: "wand.and.stars")
                toolButton(.zoom, label: "Zoom", shortcut: "Z",
                           symbol: "magnifyingglass")
                toolButton(.hand, label: "Hand", shortcut: "H / Space",
                           symbol: "hand.raised.fill")
            }

            Divider()
                .padding(.horizontal, 5)

            LazyVGrid(columns: columns, spacing: 4) {
                toolButton(.addBrush, label: "Add Brush", shortcut: "B",
                           symbol: "paintbrush.pointed.fill", badge: "plus.circle.fill")
                toolButton(.subtractBrush, label: "Remove Brush", shortcut: "B toggle / E / ⌥",
                           symbol: "paintbrush.pointed.fill", badge: "minus.circle.fill")
            }

            VStack(spacing: 2) {
                ZStack {
                    Circle()
                        .fill((model.previewTool == .subtractBrush ||
                               (model.previewTool == .addBrush && model.altDown))
                              ? Color.red.opacity(0.18)
                              : Color.accentColor.opacity(0.18))
                    Circle()
                        .stroke((model.previewTool == .subtractBrush ||
                                 (model.previewTool == .addBrush && model.altDown))
                                ? Color.red : Color.accentColor,
                                lineWidth: 1)
                }
                .frame(width: 18, height: 18)

                Text("\(Int(model.brushSize.rounded())) px")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 1)
            .help("Brush Size ([ / ])")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Brush diameter")
            .accessibilityValue("\(Int(model.brushSize.rounded())) pixels")
            .accessibilityHint("Use the left and right bracket keys to resize")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(width: 68)
        .background(.bar)
        .task(id: hoveredTool) {
            visibleTooltip = nil
            guard let hoveredTool else { return }

            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled, self.hoveredTool == hoveredTool else { return }
            visibleTooltip = hoveredTool
        }
        .onDisappear {
            hoveredTool = nil
            visibleTooltip = nil
        }
    }

    private func toolButton(_ tool: PreviewTool,
                            label: String,
                            shortcut: String,
                            symbol: String,
                            badge: String? = nil) -> some View {
        let isSelected = model.previewTool == tool
        let tooltip = ToolTooltip(label: label, shortcut: shortcut)
        return Button {
            hoveredTool = nil
            visibleTooltip = nil
            model.selectTool(tool)
        } label: {
            ZStack {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                if let badge {
                    Image(systemName: badge)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            isSelected ? Color.white : Color.accentColor,
                            isSelected ? Color.accentColor : Color(nsColor: .windowBackgroundColor)
                        )
                        .font(.system(size: 8, weight: .bold))
                        .offset(x: 8, y: 8)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(PaletteToolButtonStyle(isSelected: isSelected))
        .onHover { isHovering in
            if isHovering {
                visibleTooltip = nil
                hoveredTool = tooltip
            } else if hoveredTool == tooltip {
                hoveredTool = nil
                visibleTooltip = nil
            }
        }
        .popover(
            isPresented: Binding(
                get: { visibleTooltip == tooltip },
                set: { isPresented in
                    if !isPresented, visibleTooltip == tooltip {
                        visibleTooltip = nil
                    }
                }
            ),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .leading
        ) {
            Text("\(label) (\(shortcut))")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .fixedSize()
                .accessibilityHidden(true)
        }
        .accessibilityLabel(label)
        .accessibilityHint("Keyboard shortcut \(shortcut)")
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

private struct ToolTooltip: Equatable {
    let label: String
    let shortcut: String
}

private struct PaletteToolButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected
                          ? Color.accentColor
                          : Color.primary.opacity(configuration.isPressed ? 0.12 : 0.001))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isSelected ? Color.white.opacity(0.28) : Color.clear)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
