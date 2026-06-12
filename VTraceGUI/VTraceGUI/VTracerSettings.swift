//
//  VTracerSettings.swift
//  VTraceGUI
//

import Foundation

enum ClusteringMode: String, CaseIterable, Identifiable {
    case bw = "B/W"
    case color = "Color"
    var id: String { rawValue }
    var cliValue: String { self == .color ? "color" : "bw" }
}

enum HierarchicalMode: String, CaseIterable, Identifiable {
    case cutout = "Cutout"
    case stacked = "Stacked"
    var id: String { rawValue }
    var cliValue: String { rawValue.lowercased() }
}

enum CurveFittingMode: String, CaseIterable, Identifiable {
    case pixel = "Pixel"
    case polygon = "Polygon"
    case spline = "Spline"
    var id: String { rawValue }
    var cliValue: String { rawValue.lowercased() }
}

/// Mirrors the controls on https://www.visioncortex.org/vtracer/
/// The CLI applies the same internal transforms the webapp does
/// (speckle area = value², precision loss = 8 − value, degrees → radians),
/// so these values map 1:1 onto CLI arguments.
struct VTracerSettings: Equatable {
    var clustering: ClusteringMode = .color
    var hierarchical: HierarchicalMode = .stacked
    var filterSpeckle: Double = 4        // 1...16 px
    var colorPrecision: Double = 6       // 1...8 significant bits
    var gradientStep: Double = 16        // 0...255 layer difference
    var curveFitting: CurveFittingMode = .spline
    var cornerThreshold: Double = 60     // 0...180 degrees
    var segmentLength: Double = 4        // 3.5...10
    var spliceThreshold: Double = 45     // 0...180 degrees
    var pathPrecision: Double = 8        // 0...16 decimal places

    func cliArguments(inputPath: String, outputPath: String) -> [String] {
        var args = [
            "--input", inputPath,
            "--output", outputPath,
            "--colormode", clustering.cliValue,
            "--mode", curveFitting.cliValue,
            "--filter_speckle", String(Int(filterSpeckle)),
            "--corner_threshold", String(Int(cornerThreshold)),
            "--segment_length", String(segmentLength),
            "--splice_threshold", String(Int(spliceThreshold)),
            "--path_precision", String(Int(pathPrecision)),
        ]
        if clustering == .color {
            args += [
                "--hierarchical", hierarchical.cliValue,
                "--color_precision", String(Int(colorPrecision)),
                "--gradient_step", String(Int(gradientStep)),
            ]
        }
        return args
    }
}
