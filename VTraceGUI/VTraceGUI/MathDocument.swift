//
//  MathDocument.swift
//  Math
//
//  The persisted form of a design — everything needed to reopen it and keep
//  tweaking. Stored as a single binary-plist `.math` file: the source image
//  (so vtracer/upscale settings can still be changed), the upscaled input that
//  produced the trace, vtracer's raw SVG (so the per-shape edits below line up
//  with stable path indices on load, with no re-trace), and every knob and edit.
//

import Foundation
import UniformTypeIdentifiers

enum MathDocumentError: LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This design uses unsupported format version \(version)."
        }
    }
}

/// A user-authored translation kept separate from a path's geometry. Keeping
/// this in root-SVG coordinates lets simplification and point/brush edits keep
/// operating on the original local shape without slowly baking movement into
/// its `d` data.
nonisolated struct ShapeOffset: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    static let zero = ShapeOffset(x: 0, y: 0)
}

struct MathDocument: Codable {
    static let currentVersion = 3

    /// Math writes `.math` files, but continues to open the earlier `.vtrace`
    /// format so existing designs survive the product rename.
    static let fileExtension = "math"
    static let legacyFileExtension = "vtrace"
    static let typeIdentifier = "stfj.net.Math.math"
    static let legacyTypeIdentifier = "stfj.net.VTraceGUI.vtrace"
    static let utType = UTType(exportedAs: typeIdentifier, conformingTo: .data)
    static let legacyUTType = UTType(
        exportedAs: legacyTypeIdentifier,
        conformingTo: .data
    )
    static let readableTypes = [utType, legacyUTType]

    var version = currentVersion
    /// Used for the suggested name when exporting/saving.
    var sourceName: String

    /// The image as loaded, before any upscaling — the source of truth that
    /// upscale changes re-run from.
    var originalPNG: Data
    /// The (possibly upscaled) PNG vtracer actually traced; matches `rawSVG`,
    /// so re-tracing after load needs no re-upscale. Equals `originalPNG` when
    /// upscaling was off.
    var inputPNG: Data
    /// vtracer's untouched output. The post-process stage re-derives the
    /// preview from this, and `pathOverrides`/`editedGeometry`/`deletedPaths`
    /// are keyed by its path indices.
    var rawSVG: String

    var settings: VTracerSettings
    var upscale: UpscaleSettings
    var simplification: SimplificationSettings
    var pathOverrides: [Int: SimplificationSettings]
    var editedGeometry: [Int: String]
    var deletedPaths: [Int]
    /// Optional keeps version-1/2 documents decodable. New saves always store
    /// each shape's root-SVG translation independently from its geometry.
    var pathOffsets: [Int: ShapeOffset]? = nil
    /// Optional keeps version-1 documents decodable. New saves always include
    /// the user's manual palette groups and custom group colors.
    var manualColorGroupRules: [ManualColorGroupRule]? = nil

    var originalPixelWidth: Int
    var originalPixelHeight: Int
    var inputPixelWidth: Int
    var inputPixelHeight: Int

    func encoded() throws -> Data {
        guard (1...Self.currentVersion).contains(version) else {
            throw MathDocumentError.unsupportedVersion(version)
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> MathDocument {
        let document = try PropertyListDecoder().decode(MathDocument.self, from: data)
        guard (1...currentVersion).contains(document.version) else {
            throw MathDocumentError.unsupportedVersion(document.version)
        }
        return document
    }
}
