//
//  ColorPanelView.swift
//  VTraceGUI
//
//  Manual palette grouping and group-color editing for small traces.
//

import SwiftUI
import Foundation

struct ColorPanelView: View {
    @Bindable var model: AppModel
    @State private var groupFrames: [String: CGRect] = [:]
    @State private var ungroupFrame: CGRect = .zero
    @State private var activeDrag: PaletteDragPayload?
    @State private var dragLocation: CGPoint?
    @State private var dropTargetGroupID: String?
    @State private var isUngroupDropTarget = false

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
                    Text("Hold Space while hovering to highlight. Click to edit. Drag a tile onto another to group; drag a small swatch to move just that color.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                    ForEach(model.manualColorGroups) { group in
                        ColorGroupTile(
                            group: group,
                            isHighlighted: model.colorPreviewSpaceDown
                                && model.highlightedColorGroupID == group.id,
                            isDropTarget: dropTargetGroupID == group.id,
                            isPaletteDragging: activeDrag != nil,
                            setHighlight: {
                                model.setColorHighlight(groupID: group.id)
                            },
                            clearHighlight: {
                                model.clearColorHighlight(groupID: group.id)
                            },
                            dragChanged: updateDrag,
                            dragEnded: finishDrag,
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

                UngroupDropZone(isDropTarget: isUngroupDropTarget)
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
        .coordinateSpace(name: PaletteDragCoordinateSpace.name)
        .onPreferenceChange(PaletteGroupFramesKey.self) {
            groupFrames = $0
        }
        .onPreferenceChange(PaletteUngroupFrameKey.self) {
            ungroupFrame = $0
        }
        .overlay(alignment: .topLeading) {
            dragPreview
        }
        .onDisappear(perform: resetDrag)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Color groups")
    }

    @ViewBuilder
    private var dragPreview: some View {
        if let payload = activeDrag, let location = dragLocation {
            let sourceGroup = model.manualColorGroups.first {
                $0.members.contains(where: { $0.hex == payload.hex })
            }
            GroupDragPreview(
                hex: payload.kind == .group
                    ? sourceGroup?.colorHex ?? payload.hex
                    : payload.hex,
                count: payload.kind == .group
                    ? sourceGroup?.members.count ?? 1
                    : 1
            )
            .position(x: location.x + 12, y: location.y + 12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func updateDrag(_ payload: PaletteDragPayload, at location: CGPoint) {
        if activeDrag == nil {
            model.clearColorHighlight()
        }
        activeDrag = payload
        dragLocation = location
        dropTargetGroupID = groupTarget(for: payload, at: location)?.id
        isUngroupDropTarget = ungroupFrame.contains(location)
    }

    private func finishDrag(_ payload: PaletteDragPayload, at location: CGPoint) {
        if let target = groupTarget(for: payload, at: location) {
            _ = accept(payload, onto: target)
        } else if ungroupFrame.contains(location) {
            _ = ungroup(payload)
        }
        resetDrag()
    }

    private func groupTarget(
        for payload: PaletteDragPayload,
        at location: CGPoint
    ) -> ManualColorGroup? {
        guard let targetID = groupFrames.first(where: {
            $0.value.contains(location)
        })?.key,
        let target = model.manualColorGroups.first(where: { $0.id == targetID })
        else {
            return nil
        }

        switch payload.kind {
        case .group:
            return payload.hex == target.id ? nil : target
        case .member:
            return target.members.contains(where: { $0.hex == payload.hex })
                ? nil
                : target
        }
    }

    private func resetDrag() {
        activeDrag = nil
        dragLocation = nil
        dropTargetGroupID = nil
        isUngroupDropTarget = false
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
            return model.moveColorMember(
                payload.hex,
                ontoTargetHex: target.id
            )
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
    let isDropTarget: Bool
    let isPaletteDragging: Bool
    let setHighlight: () -> Void
    let clearHighlight: () -> Void
    let dragChanged: (PaletteDragPayload, CGPoint) -> Void
    let dragEnded: (PaletteDragPayload, CGPoint) -> Void
    let ungroupAction: (String) -> Void
    let colorAction: (String) -> Void

    @State private var isEditingColor = false

    private let memberColumns = [
        GridItem(.adaptive(minimum: 22, maximum: 24), spacing: 4),
    ]

    var body: some View {
        tileContent
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .top)
            .background(tileBackground)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PaletteGroupFramesKey.self,
                        value: [
                            group.id: proxy.frame(
                                in: .named(PaletteDragCoordinateSpace.name)
                            ),
                        ]
                    )
                }
            }
            .overlay(tileBorder)
            .overlay(alignment: .center) {
                if isDropTarget {
                    Text("GROUP HERE")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                        .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovering in
                guard !isPaletteDragging else { return }
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

            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 54)
        .contentShape(Rectangle())
        .onTapGesture(perform: openEditor)
        .paletteDragSource(
            PaletteDragPayload(kind: .group, hex: group.id),
            changed: dragChanged,
            ended: dragEnded
        )
        .help("Hold Space while hovering to highlight \(group.colorHex.uppercased()). Click to edit; drag onto another color to group.")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Group color \(group.colorHex.uppercased())")
        .accessibilityValue(groupAccessibilityValue)
        .accessibilityHint("Click to edit its hex or HSV color, or drag onto another color to group them")
        .accessibilityAction(AccessibilityActionKind.default, openEditor)
    }

    private var memberGrid: some View {
        LazyVGrid(columns: memberColumns, spacing: 3) {
            ForEach(group.members) { member in
                PaletteMemberSwatch(
                    color: member,
                    isGrouped: group.members.count > 1,
                    edit: openEditor,
                    dragChanged: dragChanged,
                    dragEnded: dragEnded,
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
    let dragChanged: (PaletteDragPayload, CGPoint) -> Void
    let dragEnded: (PaletteDragPayload, CGPoint) -> Void
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
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onTapGesture(perform: edit)
            .help("\(color.hex.uppercased()) — \(color.count) shape\(color.count == 1 ? "" : "s"). Hold Space while hovering to highlight its group; click to edit; drag to regroup.")
            .paletteDragSource(
                PaletteDragPayload(kind: .member, hex: color.hex),
                changed: dragChanged,
                ended: dragEnded
            )
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
    let isDropTarget: Bool

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
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PaletteUngroupFrameKey.self,
                    value: proxy.frame(
                        in: .named(PaletteDragCoordinateSpace.name)
                    )
                )
            }
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
    @State private var value: Double
    @State private var showsInvalidHex = false
    @FocusState private var isHexFocused: Bool

    init(colorHex: String, memberCount: Int, apply: @escaping (String) -> Void) {
        self.colorHex = colorHex
        self.memberCount = memberCount
        self.apply = apply

        let normalized = ColorMath.normalizedHex(colorHex) ?? "#808080"
        let hsv = ColorMath.hsv(from: normalized)
        _hexText = State(initialValue: normalized)
        _hue = State(initialValue: hsv.h)
        _saturation = State(initialValue: hsv.s)
        _value = State(initialValue: hsv.v)
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

            VStack(alignment: .leading, spacing: 5) {
                Text("Saturation / Value")
                    .font(.caption.weight(.semibold))

                SaturationValueField(
                    hue: hue,
                    saturation: saturation,
                    value: value,
                    update: applySaturationValue
                )
                .frame(height: 142)
            }

            hsvSlider(
                label: "H",
                accessibilityLabel: "Hue",
                value: Binding(
                    get: { hue },
                    set: { newValue in
                        hue = newValue
                        applyHSV(h: newValue, s: saturation, v: value)
                    }
                ),
                range: 0...360,
                suffix: "°"
            )

            hsvSlider(
                label: "S",
                accessibilityLabel: "Saturation",
                value: Binding(
                    get: { saturation },
                    set: { newValue in
                        saturation = newValue
                        applyHSV(h: hue, s: newValue, v: value)
                    }
                ),
                range: 0...100,
                suffix: "%"
            )

            hsvSlider(
                label: "V",
                accessibilityLabel: "Value",
                value: Binding(
                    get: { value },
                    set: { newValue in
                        value = newValue
                        applyHSV(h: hue, s: saturation, v: newValue)
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
        ColorMath.hex(h: hue, s: saturation, v: value)
    }

    private func hsvSlider(label: String,
                           accessibilityLabel: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           suffix: String) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.caption.weight(.semibold))
                .frame(width: 12)
            Slider(value: value, in: range)
                .accessibilityLabel(accessibilityLabel)
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

    private func applySaturationValue(saturation: Double, value: Double) {
        self.saturation = saturation
        self.value = value
        applyHSV(h: hue, s: saturation, v: value)
    }

    private func applyHSV(h: Double, s: Double, v: Double) {
        let hex = ColorMath.hex(h: h, s: s, v: v)
        hexText = hex
        showsInvalidHex = false
        apply(hex)
    }

    private func sync(to hex: String) {
        let hsv = ColorMath.hsv(from: hex)
        hexText = hex
        hue = hsv.h
        saturation = hsv.s
        value = hsv.v
    }
}

private struct SaturationValueField: View {
    let hue: Double
    let saturation: Double
    let value: Double
    let update: (Double, Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        Color(
                            hue: normalizedHue,
                            saturation: 1,
                            brightness: 1
                        )
                    )

                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        LinearGradient(
                            colors: [.white, .white.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .overlay {
                Circle()
                    .fill(.clear)
                    .frame(width: 15, height: 15)
                    .overlay {
                        Circle()
                            .stroke(.white, lineWidth: 2)
                    }
                    .overlay {
                        Circle()
                            .stroke(.black.opacity(0.65), lineWidth: 1)
                            .padding(2)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                    .position(markerPosition(in: size))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.primary.opacity(0.25))
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        updateColor(at: gesture.location, in: size)
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Saturation and value")
        .accessibilityValue(
            "\(Int(saturation.rounded())) percent saturation, "
                + "\(Int(value.rounded())) percent value"
        )
        .accessibilityHint("Drag horizontally for saturation and vertically for value")
    }

    private var normalizedHue: Double {
        let wrapped = ((hue.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        return wrapped / 360
    }

    private func markerPosition(in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(saturation / 100, 0), 1) * size.width,
            y: (1 - min(max(value / 100, 0), 1)) * size.height
        )
    }

    private func updateColor(at location: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let nextSaturation = min(max(location.x / size.width, 0), 1) * 100
        let nextValue = (1 - min(max(location.y / size.height, 0), 1)) * 100
        update(nextSaturation, nextValue)
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

private enum PaletteDragKind: String {
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
}

private enum PaletteDragCoordinateSpace {
    static let name = "manual-color-palette"
}

private struct PaletteGroupFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct PaletteUngroupFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private extension View {
    func paletteDragSource(
        _ payload: PaletteDragPayload,
        changed: @escaping (PaletteDragPayload, CGPoint) -> Void,
        ended: @escaping (PaletteDragPayload, CGPoint) -> Void
    ) -> some View {
        // Run beside the existing tap-to-edit gesture. A normal click never
        // reaches the five-point threshold; a drag cancels the platform tap.
        simultaneousGesture(
            DragGesture(
                minimumDistance: 5,
                coordinateSpace: .named(PaletteDragCoordinateSpace.name)
            )
            .onChanged { value in
                changed(payload, value.location)
            }
            .onEnded { value in
                ended(payload, value.location)
            }
        )
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

    static func hsv(from hex: String) -> (h: Double, s: Double, v: Double) {
        let rgb = rgb(from: normalizedHex(hex) ?? "#808080")
        let maximum = max(rgb.r, max(rgb.g, rgb.b))
        let minimum = min(rgb.r, min(rgb.g, rgb.b))
        let delta = maximum - minimum

        guard delta > .ulpOfOne else {
            return (0, 0, maximum * 100)
        }

        let saturation = maximum > 0 ? delta / maximum : 0
        let sector: Double
        if maximum == rgb.r {
            sector = ((rgb.g - rgb.b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == rgb.g {
            sector = ((rgb.b - rgb.r) / delta) + 2
        } else {
            sector = ((rgb.r - rgb.g) / delta) + 4
        }

        let hue = (sector * 60 + 360).truncatingRemainder(dividingBy: 360)
        return (hue, saturation * 100, maximum * 100)
    }

    static func hex(h: Double, s: Double, v: Double) -> String {
        let hue = ((h.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        let saturation = min(max(s / 100, 0), 1)
        let value = min(max(v / 100, 0), 1)

        let chroma = value * saturation
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

        let match = value - chroma
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
