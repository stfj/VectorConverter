//
//  ControlsView.swift
//  VTraceGUI
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

                if model.colorCount > 1 {
                    SliderRow(label: "Colors", hint: "Smash similar",
                              value: colorsBinding,
                              range: 1...Double(model.colorCount))
                }

                if let index = model.selectedPathIndex {
                    selectedShapePanel(index)
                } else if !model.lassoSelection.isEmpty {
                    lassoPanel
                } else {
                    Text("Click a shape in the preview to see its control points and simplify it individually. Delete removes it. Z = zoom tool (⌥ zooms out), V = cursor, W = magic wand lasso (scroll to set the size cutoff), hold Space to pan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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

    /// Slider position for the color budget: the right end (= every color in
    /// the trace) stores 0, meaning "no merging".
    private var colorsBinding: Binding<Double> {
        Binding(
            get: {
                let total = Double(model.colorCount)
                let budget = model.simplification.maxColors
                return budget == 0 ? total : min(budget, total)
            },
            set: { newValue in
                model.simplification.maxColors =
                    newValue >= Double(model.colorCount) ? 0 : newValue.rounded()
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
