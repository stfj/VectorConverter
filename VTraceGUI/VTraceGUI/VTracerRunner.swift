//
//  VTracerRunner.swift
//  VTraceGUI
//

import Foundation

enum VTracerError: LocalizedError {
    case binaryMissing
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "The bundled vtracer binary could not be found."
        case .conversionFailed(let message):
            return "vtracer failed: \(message)"
        }
    }
}

/// Runs the bundled vtracer CLI. Starting a new conversion terminates any in-flight one.
actor VTracerRunner {
    private var currentProcess: Process?
    private var binaryURL: URL?

    func convert(inputURL: URL, settings: VTracerSettings) async throws -> String {
        currentProcess?.terminate()

        let binary = try preparedBinary()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vtracer-\(UUID().uuidString).svg")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = binary
        process.arguments = settings.cliArguments(inputPath: inputURL.path, outputPath: outputURL.path)
        let stderrPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderrPipe

        try process.run()
        currentProcess = process

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        if currentProcess === process { currentProcess = nil }

        if process.terminationReason == .uncaughtSignal {
            // Terminated because a newer conversion superseded this one.
            throw CancellationError()
        }
        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8).flatMap {
                $0.isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? "exit code \(process.terminationStatus)"
            throw VTracerError.conversionFailed(message)
        }
        return try String(contentsOf: outputURL, encoding: .utf8)
    }

    /// Resource copies can lose the executable bit; if so, stage a chmod'd copy in tmp.
    private func preparedBinary() throws -> URL {
        if let binaryURL { return binaryURL }
        guard let bundled = Bundle.main.url(forResource: "vtracer", withExtension: nil) else {
            throw VTracerError.binaryMissing
        }
        let fm = FileManager.default
        var url = bundled
        if !fm.isExecutableFile(atPath: bundled.path) {
            let staged = fm.temporaryDirectory.appendingPathComponent("vtracer-bin")
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
