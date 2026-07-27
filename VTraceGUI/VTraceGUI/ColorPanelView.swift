//
//  ColorPanelView.swift
//  VTraceGUI
//
//  Manual palette grouping and group-color editing for small traces.
//

import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct ColorPanelView: View {
    @Bindable var model: AppModel

    private let columns = [
        GridItem(.adaptive(minimum: 72, maximum: 82), spacing: 7, alignment: .top),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Groups")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(model.colorPalette.count) after smash · \(model.outputColorCount) output")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if model.canShowManualColorPanel {
                HStack(spacing: 5) {
                    Image(systemName: "eye")
                        .foregroundStyle(.secondary)
                    Text("Hover to highlight. Click to edit. Drag onto another color to group; the destination wins.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                    ForEach(model.manualColorGroups) { group in
                        ColorGroupTile(
                            group: group,
                            isHighlighted: model.highlightedColorGroupID == group.id,
                            setHighlight: {
                                model.setColorHighlight(groupID: group.id)
                            },
                            clearHighlight: {
                                model.clearColorHighlight(groupID: group.id)
                            },
                            dropAction: { payload in
                                accept(payload, onto: group)
                            },
                            ungroupAction: { hex in
                                model.ungroup(hex: hex)
                            },
                            colorAction: { hex in
                                model.setGroupColor(groupID: group.id, hex: hex)
                            }
                        )
                    }
                }

                HStack {
                    Spacer(minLength: 0)
                    Text("\(model.manualColorGroups.count) group\(model.manualColorGroups.count == 1 ? "" : "s")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                UngroupDropZone { payload in
                    ungroup(payload)
                }
            } else if model.colorPalette.count > 31 {
                Label {
                    Text("Manual grouping is available when the post-smash palette contains 31 colors or fewer.")
                } icon: {
                    Image(systemName: "swatchpalette")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Open an image to inspect its palette.", systemImage: "swatchpalette")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Color groups")
    }

    private func accept(_ payload: PaletteDragPayload,
                        onto target: ManualColorGroup) -> Bool {
        switch payload.kind {
        case .group:
            guard payload.hex != target.id else { return false }
            model.group(sourceHex: payload.hex, ontoTargetHex: target.id)
            return true

        case .member:
            guard !target.members.contains(where: { $0.hex == payload.hex }) else {
                return false
            }

            // Pull the member out first. This matters when it is also its old
            // group's representative: `group` can then treat it as one color
            // instead of moving the entire old group.
            model.ungroup(hex: payload.hex)
            model.group(sourceHex: payload.hex, ontoTargetHex: target.id)
            return true
        }
    }

    private func ungroup(_ payload: PaletteDragPayload) -> Bool {
        switch payload.kind {
        case .member:
            model.ungroup(hex: payload.hex)
        case .group:
            guard let group = model.manualColorGroups.first(where: { $0.id == payload.hex }) else {
                return false
            }
            for member in group.members {
                model.ungroup(hex: member.hex)
            }
        }
        return true
    }
}

private struct ColorGroupTile: View {
    let group: ManualColorGroup
    let isHighlighted: Bool
    let setHighlight: () -> Void
    let clearHighlight: () -> Void
    let dropAction: (PaletteDragPayload) -> Bool
    let ungroupAction: (String) -> Void
    let colorAction: (String) -> Void

    @State private var isDropTarget = false
    @State private var isEditingColor = false

    private let memberColumns = [
        GridItem(.adaptive(minimum: 15, maximum: 17), spacing: 3),
    ]

    var body: some View {
        tileContent
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .top)
            .background(tileBackground)
            .overlay(tileBorder)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onDrop(of: PaletteDragPayload.supportedTypes,
                    isTargeted: $isDropTarget) { providers in
                PaletteDragPayload.load(from: providers, perform: dropAction)
            }
            .onHover { hovering in
                if hovering {
                    setHighlight()
                } else {
                    clearHighlight()
                }
            }
            .animation(.easeOut(duration: 0.12), value: isDropTarget)
            .animation(.easeOut(duration: 0.12), value: isHighlighted)
    }

    private var tileContent: some View {
        VStack(spacing: 5) {
            groupHeader
            memberGrid
        }
    }

    private var groupHeader: some View {
        ZStack(alignment: .topLeading) {
            groupDragHandle

            Button {
                openEditor()
            } label: {
                Image(systemName: "pencil.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help("Edit group color \(group.colorHex.uppercased())")
            .accessibilityLabel("Edit group color \(group.colorHex.uppercased())")
        }
        .popover(isPresented: $isEditingColor, arrowEdge: .leading) {
            GroupColorEditor(
                colorHex: group.colorHex,
                memberCount: group.members.count,
                apply: colorAction
            )
        }
    }

    private var groupDragHandle: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                HexColorSwatch(hex: group.colorHex)
                    .frame(width: 34, height: 34)

                if group.members.count > 1 {
                    Text("\(group.members.count)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: 5, y: -4)
                }
            }

            Text(group.colorHex.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: openEditor)
        .onDrag {
            PaletteDragPayload(kind: .group, hex: group.id).itemProvider
        } preview: {
            GroupDragPreview(hex: group.colorHex, count: group.members.count)
        }
        .help("Hover to highlight \(group.colorHex.uppercased()). Click to edit; drag onto another color to group.")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Group color \(group.colorHex.uppercased())")
        .accessibilityValue(groupAccessibilityValue)
        .accessibilityHint("Click to edit its hex or HSL color, or drag onto another color to group them")
        .accessibilityAction(AccessibilityActionKind.default, openEditor)
    }

    private var memberGrid: some View {
        LazyVGrid(columns: memberColumns, spacing: 3) {
            ForEach(group.members) { member in
                PaletteMemberSwatch(
                    color: member,
                    isGrouped: group.members.count > 1,
                    edit: openEditor,
                    ungroup: { ungroupAction(member.hex) }
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(tileFill)
    }

    private var tileBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(tileStroke, lineWidth: tileStrokeWidth)
    }

    private var tileFill: Color {
        if isDropTarget { return Color.accentColor.opacity(0.18) }
        if isHighlighted { return Color.yellow.opacity(0.15) }
        return Color.primary.opacity(0.045)
    }

    private var tileStroke: Color {
        if isDropTarget { return .accentColor }
        if isHighlighted { return .yellow }
        return Color.primary.opacity(0.12)
    }

    private var tileStrokeWidth: Double {
        isDropTarget || isHighlighted ? 2 : 1
    }

    private var groupAccessibilityValue: String {
        let noun = group.members.count == 1 ? "source color" : "source colors"
        return "\(group.members.count) \(noun)"
    }

    private func openEditor() {
        clearHighlight()
        isEditingColor = true
    }
}

private struct PaletteMemberSwatch: View {
    let color: PaletteColor
    let isGrouped: Bool
    let edit: () -> Void
    let ungroup: () -> Void

    var body: some View {
        if isGrouped {
            swatch
                .accessibilityAction(named: "Remove from group", ungroup)
        } else {
            swatch
        }
    }

    private var swatch: some View {
        HexColorSwatch(hex: color.hex)
            .frame(width: 17, height: 17)
            .contentShape(Rectangle())
            .onTapGesture(perform: edit)
            .help("\(color.hex.uppercased()) — \(color.count) shape\(color.count == 1 ? "" : "s"). Hover to highlight its group; click to edit; drag to regroup.")
            .onDrag {
                PaletteDragPayload(kind: .member, hex: color.hex).itemProvider
            } preview: {
                VStack(spacing: 4) {
                    HexColorSwatch(hex: color.hex)
                        .frame(width: 30, height: 30)
                    Text(color.hex.uppercased())
                        .font(.caption2.monospaced())
                }
                .padding(7)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .contextMenu {
                if isGrouped {
                    Button("Remove from Group") {
                        ungroup()
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Source color \(color.hex.uppercased())")
            .accessibilityValue("Used by \(color.count) shape\(color.count == 1 ? "" : "s")")
            .accessibilityHint(isGrouped
                               ? "Click to edit its group color, drag onto another group, or use the menu to remove it"
                               : "Click to edit its color, or drag onto another color to group them")
            .accessibilityAction(AccessibilityActionKind.default, edit)
    }
}

private struct UngroupDropZone: View {
    let dropAction: (PaletteDragPayload) -> Bool

    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isDropTarget
                  ? "arrow.down.circle.fill"
                  : "arrow.down.circle")
            Text(isDropTarget ? "Release to ungroup" : "Drop here to ungroup")
                .font(.caption.weight(.medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(isDropTarget ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isDropTarget
                      ? Color.accentColor.opacity(0.12)
                      : Color.primary.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(
                    isDropTarget ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: isDropTarget ? 2 : 1, dash: [4, 3])
                )
        }
        .onDrop(of: PaletteDragPayload.supportedTypes,
                isTargeted: $isDropTarget) { providers in
            PaletteDragPayload.load(from: providers, perform: dropAction)
        }
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ungroup drop area")
        .accessibilityHint("Drop a color here to remove it from its group")
    }
}

private struct GroupDragPreview: View {
    let hex: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            HexColorSwatch(hex: hex)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(hex.uppercased())
                    .font(.caption.monospaced())
                Text("\(count) color\(count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct GroupColorEditor: View {
    let colorHex: String
    let memberCount: Int
    let apply: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var hexText: String
    @State private var hue: Double
    @State private var saturation: Double
    @State private var lightness: Double
    @State private var showsInvalidHex = false
    @FocusState private var isHexFocused: Bool

    init(colorHex: String, memberCount: Int, apply: @escaping (String) -> Void) {
        self.colorHex = colorHex
        self.memberCount = memberCount
        self.apply = apply

        let normalized = ColorMath.normalizedHex(colorHex) ?? "#808080"
        let hsl = ColorMath.hsl(from: normalized)
        _hexText = State(initialValue: normalized)
        _hue = State(initialValue: hsl.h)
        _saturation = State(initialValue: hsl.s)
        _lightness = State(initialValue: hsl.l)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HexColorSwatch(hex: liveHex)
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Group Color")
                        .font(.headline)
                    Text("\(memberCount) source color\(memberCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
                .accessibilityLabel("Close color editor")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("#RRGGBB", text: $hexText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .focused($isHexFocused)
                        .onSubmit(applyHex)
                        .accessibilityLabel("Hex color")

                    Button("Apply", action: applyHex)
                        .keyboardShortcut(.return, modifiers: [])
                }

                if showsInvalidHex {
                    Text("Enter a 3- or 6-digit hex color.")
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else {
                    Text("Paste a hex value, then press Return.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            hslSlider(
                label: "H",
                value: Binding(
                    get: { hue },
                    set: { newValue in
                        hue = newValue
                        applyHSL(h: newValue, s: saturation, l: lightness)
                    }
                ),
                range: 0...360,
                suffix: "°"
            )

            hslSlider(
                label: "S",
                value: Binding(
                    get: { saturation },
                    set: { newValue in
                        saturation = newValue
                        applyHSL(h: hue, s: newValue, l: lightness)
                    }
                ),
                range: 0...100,
                suffix: "%"
            )

            hslSlider(
                label: "L",
                value: Binding(
                    get: { lightness },
                    set: { newValue in
                        lightness = newValue
                        applyHSL(h: hue, s: saturation, l: newValue)
                    }
                ),
                range: 0...100,
                suffix: "%"
            )
        }
        .padding(14)
        .frame(width: 270)
        .onAppear {
            isHexFocused = true
        }
    }

    private var liveHex: String {
        ColorMath.hex(h: hue, s: saturation, l: lightness)
    }

    private func hslSlider(label: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           suffix: String) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(width: 12)
            Slider(value: value, in: range)
                .accessibilityLabel(label == "H" ? "Hue" : label == "S" ? "Saturation" : "Lightness")
                .accessibilityValue("\(Int(value.wrappedValue.rounded()))\(suffix)")
            Text("\(Int(value.wrappedValue.rounded()))\(suffix)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func applyHex() {
        guard let normalized = ColorMath.normalizedHex(hexText) else {
            showsInvalidHex = true
            return
        }

        showsInvalidHex = false
        sync(to: normalized)
        apply(normalized)
    }

    private func applyHSL(h: Double, s: Double, l: Double) {
        let hex = ColorMath.hex(h: h, s: s, l: l)
        hexText = hex
        showsInvalidHex = false
        apply(hex)
    }

    private func sync(to hex: String) {
        let hsl = ColorMath.hsl(from: hex)
        hexText = hex
        hue = hsl.h
        saturation = hsl.s
        lightness = hsl.l
    }
}

private struct HexColorSwatch: View {
    let hex: String

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(ColorMath.color(from: hex))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.primary.opacity(0.22))
            }
    }
}

private enum PaletteDragKind: String, Codable {
    case group
    case member
}

private struct PaletteDragPayload {
    let kind: PaletteDragKind
    let hex: String

    init(kind: PaletteDragKind, hex: String) {
        self.kind = kind
        self.hex = PaletteHex.normalize(hex) ?? hex
    }

    /// Use AppKit's direct data-provider path rather than SwiftUI's Codable
    /// Transferable bridge, which is unreliable inside this macOS ScrollView.
    var itemProvider: NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(encoded.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: Self.dragType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private static let dragType = UTType(
        exportedAs: "com.zachgage.vectorconverter.palette-color-v1"
    )
    static let supportedTypes = [dragType]

    static func load(from providers: [NSItemProvider],
                     perform action: @escaping (PaletteDragPayload) -> Bool) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(dragType.identifier)
        }) else {
            return false
        }

        provider.loadDataRepresentation(
            forTypeIdentifier: dragType.identifier
        ) { data, _ in
            guard let data,
                  let text = String(data: data, encoding: .utf8),
                  let payload = PaletteDragPayload(encoded: text) else { return }
            Task { @MainActor in
                _ = action(payload)
            }
        }
        return true
    }

    private static let prefix = "vectorconverter-palette-v1"

    private var encoded: String {
        "\(Self.prefix)|\(kind.rawValue)|\(hex)"
    }

    private init?(encoded: String) {
        let pieces = encoded.split(separator: "|", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              pieces[0] == Substring(Self.prefix),
              let kind = PaletteDragKind(rawValue: String(pieces[1])),
              let hex = PaletteHex.normalize(String(pieces[2])) else {
            return nil
        }
        self.kind = kind
        self.hex = hex
    }
}

private enum ColorMath {
    static func normalizedHex(_ input: String) -> String? {
        var digits = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }

        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }

        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return "#\(digits.uppercased())"
    }

    static func color(from hex: String) -> Color {
        let components = rgb(from: normalizedHex(hex) ?? "#808080")
        return Color(
            .sRGB,
            red: components.r,
            green: components.g,
            blue: components.b,
            opacity: 1
        )
    }

    static func hsl(from hex: String) -> (h: Double, s: Double, l: Double) {
        let rgb = rgb(from: normalizedHex(hex) ?? "#808080")
        let maximum = max(rgb.r, max(rgb.g, rgb.b))
        let minimum = min(rgb.r, min(rgb.g, rgb.b))
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2

        guard delta > .ulpOfOne else {
            return (0, 0, lightness * 100)
        }

        let saturation = delta / (1 - abs(2 * lightness - 1))
        let sector: Double
        if maximum == rgb.r {
            sector = ((rgb.g - rgb.b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == rgb.g {
            sector = ((rgb.b - rgb.r) / delta) + 2
        } else {
            sector = ((rgb.r - rgb.g) / delta) + 4
        }

        let hue = (sector * 60 + 360).truncatingRemainder(dividingBy: 360)
        return (hue, saturation * 100, lightness * 100)
    }

    static func hex(h: Double, s: Double, l: Double) -> String {
        let hue = ((h.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        let saturation = min(max(s / 100, 0), 1)
        let lightness = min(max(l / 100, 0), 1)

        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = hue / 60
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let partial: (Double, Double, Double)

        switch sector {
        case 0..<1: partial = (chroma, x, 0)
        case 1..<2: partial = (x, chroma, 0)
        case 2..<3: partial = (0, chroma, x)
        case 3..<4: partial = (0, x, chroma)
        case 4..<5: partial = (x, 0, chroma)
        default: partial = (chroma, 0, x)
        }

        let match = lightness - chroma / 2
        let red = Int(((partial.0 + match) * 255).rounded())
        let green = Int(((partial.1 + match) * 255).rounded())
        let blue = Int(((partial.2 + match) * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private static func rgb(from normalizedHex: String) -> (r: Double, g: Double, b: Double) {
        let value = UInt32(normalizedHex.dropFirst(), radix: 16) ?? 0x808080
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }
}
