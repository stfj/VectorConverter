//
//  ColorGrouping.swift
//  VTraceGUI
//
//  Shared model types for the small-palette manual grouping editor.
//

import Foundation

nonisolated struct PaletteColor: Identifiable, Hashable, Sendable {
    let hex: String
    let count: Int

    var id: String { hex }
}

/// A presentation-ready group. Its stable ID is the first original color in
/// `members`; `colorHex` is the color every member currently renders as.
nonisolated struct ManualColorGroup: Identifiable, Hashable, Sendable {
    let id: String
    let colorHex: String
    let members: [PaletteColor]
}

/// Compact persisted form. Members are palette hex values in group order, with
/// the destination/representative first. Keeping this hex-keyed shape makes
/// existing design documents backward-compatible.
nonisolated struct ManualColorGroupRule: Codable, Equatable, Sendable {
    var members: [String]
    var colorHex: String
}

nonisolated enum PaletteHex {
    static func normalize(_ input: String) -> String? {
        var digits = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return "#\(digits.uppercased())"
    }
}
