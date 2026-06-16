//
//  VTraceDocument.swift
//  VTraceGUI
//
//  The persisted form of a design — everything needed to reopen it and keep
//  tweaking. Stored as a single binary-plist `.vtrace` file: the source image
//  (so vtracer/upscale settings can still be changed), the upscaled input that
//  produced the trace, vtracer's raw SVG (so the per-shape edits below line up
//  with stable path indices on load, with no re-trace), and every knob and edit.
//

import Foundation
import UniformTypeIdentifiers

struct VTraceDocument: Codable {
    static let currentVersion = 1

    /// Filename extension and panel type for `.vtrace` design files.
    static let fileExtension = "vtrace"
    static let utType = UTType(filenameExtension: fileExtension)

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

    var originalPixelWidth: Int
    var originalPixelHeight: Int
    var inputPixelWidth: Int
    var inputPixelHeight: Int

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> VTraceDocument {
        try PropertyListDecoder().decode(VTraceDocument.self, from: data)
    }
}
