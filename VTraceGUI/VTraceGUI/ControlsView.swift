//
//  ControlsView.swift
//  Math
//

import SwiftUI

struct ControlsView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("Upscale")

                Toggle("Upscayl (Digital Art)", isOn: $model.upscale.enabled)

                if model.upscale.enabled {
                    Picker("Scale", selection: $model.upscale.scale) {
                        ForEach(UpscaleScale.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Toggle("Double Upscayl", isOn: $model.upscale.doublePass)

                    upscaleCaption
                }

                Divider()

                sectionHeader("Clustering")

                Picker("Clustering", selection: $model.settings.clustering) {
                    ForEach(ClusteringMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if model.settings.clustering == .color {
                    Picker("Hierarchy", selection: $model.settings.hierarchical) {
                        ForEach(HierarchicalMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                SliderRow(label: "Filter Speckle", hint: "Cleaner",
                          value: $model.settings.filterSpeckle, range: 1...16)

                if model.settings.clustering == .color {
                    SliderRow(label: "Color Precision", hint: "More accurate",
                              value: $model.settings.colorPrecision, range: 1...8)
                    SliderRow(label: "Gradient Step", hint: "Less layers",
                              value: $model.settings.gradientStep, range: 0...255)
                }

                Divider()

                sectionHeader("Curve Fitting")

                Picker("Curve Fitting", selection: $model.settings.curveFitting) {
                    ForEach(CurveFittingMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if model.settings.curveFitting == .spline {
                    SliderRow(label: "Corner Threshold", hint: "Smoother",
                              value: $model.settings.cornerThreshold, range: 0...180)
                    SliderRow(label: "Segment Length", hint: "More coarse",
                              value: $model.settings.segmentLength, range: 3.5...10,
                              step: 0.5, fractionDigits: 1)
                    SliderRow(label: "Splice Threshold", hint: "Less accurate",
                              value: $model.settings.spliceThreshold, range: 0...180)
                    SliderRow(label: "Path Precision", hint: "More digits",
                              value: $model.settings.pathPrecision, range: 0...16)
                }

                Divider()

                sectionHeader("Simplification")

                SliderRow(label: "Simplify", hint: "Fewer points",
                          value: $model.simplification.tolerance, range: 0...10,
                          step: 0.1, fractionDigits: 1)
                SliderRow(label: "Smoothing", hint: "Rounder",
                          value: $model.simplification.smoothing, range: 0...30,
                          step: 0.5, fractionDigits: 1)
                SliderRow(label: "Max Nodes", hint: "Point budget",
                          value: $model.simplification.maxNodes, range: 0...32,
                          offBelow: 3)

                if model.simplification.isActive {
                    SliderRow(label: "Corner Angle", hint: "Smoother",
                              value: $model.simplification.cornerAngle, range: 15...180)
                }

                if let index = model.selectedPathIndex {
                    selectedShapePanel(index)
                } else if !model.lassoSelection.isEmpty {
                    lassoPanel
                } else {
                    Text("Choose tools from the left toolbar. V selects and drags shapes, Z zooms (⌥ zooms out), W lassos, A edits points, and H or Space pans. Select one shape, then press B to choose the brush; press B again to toggle Add/Remove, or hold ⌥ for Remove temporarily. [ and ] resize it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                sectionHeader("Colors")

                if model.colorCount > 1 {
                    colorsSliderRow
                }

                ColorPanelView(
                    model: model,
                    beginColorEdit: model.beginColorEdit,
                    endColorEdit: model.endColorEdit
                )
                    .disabled(!model.editingInteractionEnabled)

                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .frame(width: 290)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }

    @ViewBuilder
    private var upscaleCaption: some View {
        if model.isUpscaling {
            ProgressView(value: model.upscaleProgress) {
                Text("Upscayling… \(Int(model.upscaleProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
        } else if let original = model.originalPixelSize {
            let factor = model.upscale.totalFactor
            Text("\(factor)× total — \(Int(original.width)) × \(Int(original.height)) → \(Int(original.width) * factor) × \(Int(original.height) * factor) px")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("\(model.upscale.totalFactor)× total")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func selectedShapePanel(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Shape \(index + 1)")
                    .font(.callout.weight(.semibold))
                if model.pathOverrides[index] != nil {
                    Text("custom")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.25), in: Capsule())
                }
                Spacer()
                Button("Delete", role: .destructive) {
                    model.deleteSelectedShape()
                }
                .controlSize(.small)
                Button("Deselect") {
                    model.selectedPathIndex = nil
                }
                .controlSize(.small)
            }

            SliderRow(label: "Simplify", hint: "This shape",
                      value: overrideBinding(index, \.tolerance), range: 0...10,
                      step: 0.1, fractionDigits: 1)
            SliderRow(label: "Smoothing", hint: "Rounder",
                      value: overrideBinding(index, \.smoothing), range: 0...30,
                      step: 0.5, fractionDigits: 1)
            SliderRow(label: "Max Nodes", hint: "Point budget",
                      value: overrideBinding(index, \.maxNodes), range: 0...32,
                      offBelow: 3)

            if effective(index).isActive {
                SliderRow(label: "Corner Angle", hint: "Smoother",
                          value: overrideBinding(index, \.cornerAngle), range: 15...180)
            }

            if model.pathOverrides[index] != nil {
                Button("Reset to Global") {
                    model.clearOverride(for: index)
                }
                .controlSize(.small)
            }

            if model.previewTool == .anchor {
                Divider()
                if model.selectedAnchors.isEmpty {
                    Text("Point tool — click anchor points, or drag a box around them (⇧-drag to add), then press Delete.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("\(model.selectedAnchors.count) point\(model.selectedAnchors.count == 1 ? "" : "s") selected")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Button("Delete Points", role: .destructive) {
                            model.deleteSelectedAnchors()
                        }
                        .controlSize(.small)
                    }
                }
            }

            if model.previewTool.isBrush {
                Divider()
                Text(model.previewTool == .addBrush
                     ? "Add brush — paint anywhere to merge a round stroke into this shape. Use [ and ] to resize."
                     : "Subtract brush — paint across this shape to cut the round stroke out. Use [ and ] to resize.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.4))
        }
    }

    private var lassoPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(model.lassoSelection.count) shapes selected")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button("Deselect") {
                    model.setLassoSelection([])
                }
                .controlSize(.small)
            }
            Text("Scroll to adjust the size cutoff — bigger shapes drop out as the threshold goes down.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Delete \(model.lassoSelection.count) Shapes", role: .destructive) {
                model.deleteSelectedShape()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.4))
        }
    }

    private var colorsSliderRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Smash Similar")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(displayedColorBudget, format: .number.grouping(.never))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: colorsSliderPosition, in: 0...1)
                .accessibilityLabel("Colors")
                .accessibilityValue("\(displayedColorBudget)")
        }
    }

    /// The effective integer budget shown to the user. A stored value of zero
    /// means every traced color is retained.
    private var displayedColorBudget: Int {
        let total = max(model.colorCount, 1)
        let stored = Int(model.simplification.maxColors.rounded())
        return stored <= 0 ? total : min(max(stored, 1), total)
    }

    /// A logarithmic slider gives small color budgets substantially more room
    /// while still fitting traces with thousands of colors. The right endpoint
    /// stores 0, preserving the model's "no merging" sentinel.
    private var colorsSliderPosition: Binding<Double> {
        Binding(
            get: {
                let total = Double(max(model.colorCount, 2))
                return log(Double(displayedColorBudget)) / log(total)
            },
            set: { newPosition in
                let total = Double(max(model.colorCount, 2))
                let position = min(max(newPosition, 0), 1)

                if position >= 0.999_999 {
                    model.simplification.maxColors = 0
                    return
                }

                let budget = exp(log(total) * position).rounded()
                model.simplification.maxColors = min(max(budget, 1), total - 1)
            }
        )
    }

    private func effective(_ index: Int) -> SimplificationSettings {
        model.effectiveSimplification(for: index)
    }

    /// Reads the shape's effective settings; the first write creates an override.
    private func overrideBinding(_ index: Int,
                                 _ keyPath: WritableKeyPath<SimplificationSettings, Double>) -> Binding<Double> {
        Binding(
            get: { model.effectiveSimplification(for: index)[keyPath: keyPath] },
            set: { newValue in
                var settings = model.effectiveSimplification(for: index)
                settings[keyPath: keyPath] = newValue
                model.setOverride(settings, for: index)
            }
        )
    }
}

struct SliderRow: View {
    let label: String
    let hint: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var fractionDigits: Int = 0
    /// Values below this read as "Off".
    var offBelow: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
                    .font(.callout.weight(.medium))
                Text("(\(hint))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let offBelow, value < offBelow {
                    Text("Off")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(value, format: .number.precision(.fractionLength(fractionDigits)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}
