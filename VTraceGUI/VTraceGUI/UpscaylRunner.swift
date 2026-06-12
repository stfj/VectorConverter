//
//  UpscaylRunner.swift
//  VTraceGUI
//

import Foundation

enum UpscaleScale: Int, CaseIterable, Identifiable {
    case x2 = 2
    case x3 = 3
    case x4 = 4
    var id: Int { rawValue }
    var label: String { "\(rawValue)×" }
}

/// AI upscaling applied to the source image before vtracer sees it.
/// Runs the bundled upscayl-ncnn engine with Upscayl's Digital Art model.
struct UpscaleSettings: Equatable {
    var enabled = true
    var scale: UpscaleScale = .x4
    /// Upscayl's "Double Upscayl": feed the upscaled image through the model
    /// a second time, squaring the overall scale.
    var doublePass = false

    var totalFactor: Int {
        doublePass ? scale.rawValue * scale.rawValue : scale.rawValue
    }
}

enum UpscaylError: LocalizedError {
    case binaryMissing
    case upscaleFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "The bundled upscayl-bin engine could not be found."
        case .upscaleFailed(let message):
            return "Upscayl failed: \(message)"
        }
    }
}

/// Runs the bundled upscayl-bin CLI. Starting a new upscale terminates any in-flight one.
actor UpscaylRunner {
    static let modelName = "digital-art-4x"

    private var currentProcess: Process?
    private var binaryURL: URL?
    private var modelsDirURL: URL?

    /// Stops any in-flight upscale (e.g. when upscaling is toggled off).
    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
    }

    /// Upscales `input` into `output`, reporting overall progress in 0...1.
    /// A double pass routes through a temporary intermediate file.
    func upscale(input: URL, output: URL, settings: UpscaleSettings,
                 progress: @escaping @MainActor (Double) -> Void) async throws {
        currentProcess?.terminate()

        let binary = try preparedBinary()
        let modelsDir = try preparedModelsDir()

        let passes = settings.doublePass ? 2 : 1
        var source = input
        for pass in 0..<passes {
            let isLast = pass == passes - 1
            let destination = isLast
                ? output
                : FileManager.default.temporaryDirectory
                    .appendingPathComponent("upscayl-pass-\(UUID().uuidString).png")
            try await runPass(binary: binary, modelsDir: modelsDir,
                              input: source, output: destination,
                              scale: settings.scale.rawValue) { passProgress in
                await progress((Double(pass) + passProgress) / Double(passes))
            }
            if pass > 0 {
                try? FileManager.default.removeItem(at: source)
            }
            source = destination
        }
    }

    private func runPass(binary: URL, modelsDir: URL, input: URL, output: URL,
                         scale: Int,
                         progress: (Double) async -> Void) async throws {
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "-i", input.path,
            "-o", output.path,
            "-s", String(scale),
            "-n", Self.modelName,
            "-m", modelsDir.path,
            "-f", "png",
        ]
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        currentProcess = process

        // The engine prints percentage lines ("12.34%") to stderr as it works.
        var transcript = ""
        do {
            for try await line in stderrPipe.fileHandleForReading.bytes.lines {
                transcript += line + "\n"
                if let fraction = Self.parseProgress(line) {
                    await progress(fraction)
                }
            }
        } catch {
            // Stream errors surface through the exit status below.
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        if currentProcess === process { currentProcess = nil }

        if process.terminationReason == .uncaughtSignal {
            // Terminated because a newer upscale superseded this one.
            throw CancellationError()
        }
        guard process.terminationStatus == 0 else {
            let message = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpscaylError.upscaleFailed(
                message.isEmpty ? "exit code \(process.terminationStatus)" : message)
        }
    }

    private static func parseProgress(_ line: String) -> Double? {
        var text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.hasSuffix("%") { text = String(text.dropLast()) }
        guard let value = Double(text), (0...100).contains(value) else { return nil }
        return value / 100
    }

    /// The engine refuses any model directory not literally named "models",
    /// and bundle resources are flattened — so stage a tmp "models" dir of
    /// symlinks to the bundled model files.
    private func preparedModelsDir() throws -> URL {
        if let modelsDirURL { return modelsDirURL }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("upscayl-models/models", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for ext in ["bin", "param"] {
            guard let bundled = Bundle.main.url(forResource: Self.modelName, withExtension: ext) else {
                throw UpscaylError.binaryMissing
            }
            let link = dir.appendingPathComponent(bundled.lastPathComponent)
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: bundled)
        }
        modelsDirURL = dir
        return dir
    }

    /// Resource copies can lose the executable bit; if so, stage a chmod'd copy in tmp.
    private func preparedBinary() throws -> URL {
        if let binaryURL { return binaryURL }
        guard let bundled = Bundle.main.url(forResource: "upscayl-bin", withExtension: nil) else {
            throw UpscaylError.binaryMissing
        }
        let fm = FileManager.default
        var url = bundled
        if !fm.isExecutableFile(atPath: bundled.path) {
            let staged = fm.temporaryDirectory.appendingPathComponent("upscayl-bin")
            if fm.fileExists(atPath: staged.path) {
                try? fm.removeItem(at: staged)
            }
            try fm.copyItem(at: bundled, to: staged)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            url = staged
        }
        binaryURL = url
        return url
    }
}
