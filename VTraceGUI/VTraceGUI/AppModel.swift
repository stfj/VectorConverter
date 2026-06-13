//
//  AppModel.swift
//  VTraceGUI
//

import SwiftUI
import Observation
import UniformTypeIdentifiers

enum PreviewTool {
    case cursor
    case zoom
    case wand
}

@MainActor
@Observable
final class AppModel {
    var settings = VTracerSettings() {
        didSet { if settings != oldValue { scheduleConversion() } }
    }

    /// AI upscaling (Upscayl, Digital Art model) applied to the source image
    /// before tracing; re-runs from the cached original on any change.
    var upscale = UpscaleSettings() {
        didSet { if upscale != oldValue { prepareInput() } }
    }

    /// Post-processing applied on top of vtracer's output; re-runs on the
    /// cached raw SVG without invoking the CLI again.
    var simplification = SimplificationSettings() {
        didSet { if simplification != oldValue { schedulePostProcess() } }
    }

    /// Active preview tool: cursor selects shapes, zoom clicks zoom in
    /// (⌥-click zooms out). Z/V switch tools.
    private(set) var previewTool = PreviewTool.cursor

    /// True while the space bar is held: temporary hand tool for panning,
    /// also hides the selected shape's control points.
    private(set) var spaceDown = false

    /// True while ⌥ is held (zoom tool shows the zoom-out cursor).
    private(set) var altDown = false

    /// Index (document order) of the shape selected by clicking in the preview.
    var selectedPathIndex: Int?

    /// Shapes selected by the magic wand lasso (W). Mutually exclusive with
    /// the single click-selection above.
    private(set) var lassoSelection: Set<Int> = []

    /// Per-shape simplification settings, keyed by path index in the raw SVG.
    /// Cleared whenever vtracer re-runs, since shape identity changes.
    private(set) var pathOverrides: [Int: SimplificationSettings] = [:]

    /// Raw-SVG indices of shapes the user deleted. Cleared on re-trace.
    private(set) var deletedPaths: Set<Int> = []

    /// Deletion order, for undo. Each entry is one delete action; a wand
    /// delete removes (and restores) its whole group at once.
    private var deletionStack: [[Int]] = []

    /// Bumped each time a new source image is loaded; the preview keys off this.
    private(set) var imageVersion = 0
    private(set) var sourcePixelSize: CGSize?
    /// Pixel size of the image as loaded, before any upscaling.
    private(set) var originalPixelSize: CGSize?
    private(set) var isUpscaling = false
    /// 0...1 while isUpscaling.
    private(set) var upscaleProgress = 0.0
    private(set) var svgText: String?
    private(set) var isConverting = false
    private(set) var pathCount = 0
    private(set) var rawPointCount: Int?
    private(set) var pointCount: Int?
    private(set) var nodeCount: Int?
    private(set) var lastConversionTime: TimeInterval?
    var errorMessage: String?

    /// Holds the preview page and the normalized input PNG.
    let workDirectory: URL
    var inputPNGURL: URL { workDirectory.appendingPathComponent("input.png") }
    /// The image as loaded, before any upscaling; upscale re-runs start here.
    var originalPNGURL: URL { workDirectory.appendingPathComponent("original.png") }

    private var sourceName = "export"
    private var hasImage = false
    private var rawSVG: String?
    private let runner = VTracerRunner()
    private let upscaler = UpscaylRunner()
    private var upscaleTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var postProcessDebounceTask: Task<Void, Never>?
    private var generation = 0
    /// Staleness for the upscale pipeline only; `generation` also moves on
    /// trace/post-process changes, which shouldn't orphan a finishing upscale.
    private var inputGeneration = 0

    init() {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VTraceGUI-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        installKeyMonitor()
    }

    // MARK: - Keyboard (space = peek under control points, delete = remove shape)

    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
    }

    /// Returns nil when the event is consumed.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            altDown = event.modifierFlags.contains(.option)
            return event
        }

        // Leave panels (open/save dialogs) and any text editing alone.
        guard let window = event.window, !(window is NSPanel) else { return event }
        if window.firstResponder is NSTextView { return event }

        // Tool switching: plain Z / V (no modifiers, so ⌘Z stays undo).
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           let key = event.charactersIgnoringModifiers?.lowercased() {
            if key == "z" {
                previewTool = .zoom
                return nil
            }
            if key == "v" {
                previewTool = .cursor
                return nil
            }
            if key == "w" {
                previewTool = .wand
                return nil
            }
        }

        // ⌘C / ⌘V: handle here because the preview WKWebView becomes first
        // responder when clicked and swallows these key equivalents before
        // the menu bar sees them.
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command],
           let key = event.charactersIgnoringModifiers?.lowercased() {
            if key == "c", svgText != nil {
                copySVGToClipboard()
                return nil
            }
            if key == "v" {
                pasteFromClipboard()
                return nil
            }
        }

        switch event.keyCode {
        case 49: // space: hand tool while held (and hide control points)
            if event.type == .keyDown {
                if !event.isARepeat { spaceDown = true }
            } else {
                spaceDown = false
            }
            return nil
        case 51, 117: // backspace, forward delete
            guard event.type == .keyDown,
                  selectedPathIndex != nil || !lassoSelection.isEmpty else { return event }
            deleteSelectedShape()
            return nil
        default:
            return event
        }
    }

    /// Deletes the wand selection if there is one, else the clicked shape.
    func deleteSelectedShape() {
        if !lassoSelection.isEmpty {
            let group = lassoSelection.sorted()
            deletedPaths.formUnion(group)
            deletionStack.append(group)
            lassoSelection = []
            schedulePostProcess()
            return
        }
        guard let index = selectedPathIndex else { return }
        deletedPaths.insert(index)
        deletionStack.append([index])
        selectedPathIndex = nil
        schedulePostProcess()
    }

    var canUndoDeletion: Bool { !deletionStack.isEmpty }

    func undoDeleteShape() {
        guard let group = deletionStack.popLast() else { return }
        deletedPaths.subtract(group)
        if group.count == 1 {
            selectedPathIndex = group[0]
            lassoSelection = []
        } else {
            setLassoSelection(Set(group))
        }
        schedulePostProcess()
    }

    // MARK: - Selection

    /// Single click-selection from the preview; replaces any wand selection.
    func selectPath(_ index: Int?) {
        selectedPathIndex = index
        lassoSelection = []
    }

    func setLassoSelection(_ indices: Set<Int>) {
        lassoSelection = indices
        if !indices.isEmpty { selectedPathIndex = nil }
    }

    // MARK: - Image input

    func loadImage(from url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Could not read \(url.lastPathComponent)."
            return
        }
        sourceName = url.deletingPathExtension().lastPathComponent
        loadImage(data: data)
    }

    /// Normalizes any readable image into a PNG in the work directory, so the
    /// CLI and the preview page always see the same input format.
    func loadImage(data: Data) {
        guard let rep = NSBitmapImageRep(data: data) ?? Self.repViaNSImage(data),
              let png = rep.representation(using: .png, properties: [:]) else {
            errorMessage = "That file doesn't look like a readable image."
            return
        }
        do {
            try png.write(to: originalPNGURL)
            // Show the source bitmap right away; upscaling swaps it out when done.
            try png.write(to: inputPNGURL)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        originalPixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        sourcePixelSize = originalPixelSize
        hasImage = true
        svgText = nil
        rawSVG = nil
        pathCount = 0
        rawPointCount = nil
        pointCount = nil
        lastConversionTime = nil
        errorMessage = nil
        selectedPathIndex = nil
        lassoSelection = []
        pathOverrides = [:]
        deletedPaths = []
        deletionStack = []
        imageVersion += 1
        prepareInput()
    }

    private static func repViaNSImage(_ data: Data) -> NSBitmapImageRep? {
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    func pasteFromClipboard() {
        if !loadImage(fromPasteboard: .general, fallbackName: "pasted-image") {
            errorMessage = "No image on the clipboard."
        }
    }

    /// Shared by paste and drag-and-drop. Returns false if the pasteboard
    /// holds nothing readable as an image.
    @discardableResult
    func loadImage(fromPasteboard pasteboard: NSPasteboard, fallbackName: String) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: Self.imageURLReadingOptions) as? [URL],
           let url = urls.first {
            loadImage(from: url)
            return true
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            sourceName = fallbackName
            loadImage(data: data)
            return true
        }
        return false
    }

    static let imageURLReadingOptions: [NSPasteboard.ReadingOptionKey: Any] =
        [.urlReadingContentsConformToTypes: [UTType.image.identifier]]

    func openImagePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            loadImage(from: url)
        }
    }

    // MARK: - Export

    func exportSVG() {
        guard let svgText else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg]
        panel.nameFieldStringValue = sourceName + ".svg"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try exportableSVG(svgText).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func copySVGToClipboard() {
        guard let svgText else { return }
        let cleaned = exportableSVG(svgText)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(cleaned, forType: .string)
        if let data = cleaned.data(using: .utf8) {
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType("public.svg-image"))
        }
    }

    /// Deleted shapes are kept as empty-d placeholders in the preview (to hold
    /// path indices stable); strip them from anything that leaves the app.
    private func exportableSVG(_ svg: String) -> String {
        svg.replacingOccurrences(
            of: "<path d=\"\"[^>]*/>\\n?",
            with: "",
            options: .regularExpression
        )
    }

    // MARK: - Per-shape overrides

    /// The settings currently in effect for a shape (its override, else global).
    func effectiveSimplification(for index: Int) -> SimplificationSettings {
        pathOverrides[index] ?? simplification
    }

    func setOverride(_ settings: SimplificationSettings, for index: Int) {
        pathOverrides[index] = settings
        schedulePostProcess()
    }

    func clearOverride(for index: Int) {
        guard pathOverrides.removeValue(forKey: index) != nil else { return }
        schedulePostProcess()
    }

    // MARK: - Upscaling

    /// Rebuilds input.png from the cached original — upscaled when enabled,
    /// a straight copy otherwise — then kicks off a fresh trace.
    private func prepareInput() {
        guard hasImage else { return }
        upscaleTask?.cancel()
        // Invalidate any in-flight conversion; it traced the old input.
        generation += 1
        inputGeneration += 1
        let gen = inputGeneration

        guard upscale.enabled else {
            isUpscaling = false
            Task { [upscaler] in await upscaler.cancel() }
            do {
                try? FileManager.default.removeItem(at: inputPNGURL)
                try FileManager.default.copyItem(at: originalPNGURL, to: inputPNGURL)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            sourcePixelSize = originalPixelSize
            imageVersion += 1
            scheduleConversion(immediately: true)
            return
        }

        isUpscaling = true
        upscaleProgress = 0
        let settings = upscale
        let source = originalPNGURL
        // Upscayl writes to a side file so an in-flight vtracer never reads a
        // half-written input.png; the swap happens after it finishes.
        let staging = workDirectory.appendingPathComponent("upscaled.png")
        let destination = inputPNGURL
        upscaleTask = Task { [weak self, upscaler] in
            do {
                try await upscaler.upscale(input: source, output: staging,
                                           settings: settings) { [weak self] fraction in
                    guard let self, gen == self.inputGeneration else { return }
                    self.upscaleProgress = fraction
                }
                guard let self, gen == self.inputGeneration else { return }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: staging, to: destination)
                if let rep = NSBitmapImageRep(data: try Data(contentsOf: destination)) {
                    self.sourcePixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                }
                self.isUpscaling = false
                self.imageVersion += 1
                self.scheduleConversion(immediately: true)
            } catch is CancellationError {
                // Superseded by a newer upscale; the newer one owns the UI state.
            } catch {
                guard let self, gen == self.inputGeneration else { return }
                self.isUpscaling = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Conversion

    private func scheduleConversion(immediately: Bool = false) {
        guard hasImage else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            self?.startConversion()
        }
    }

    private func startConversion() {
        generation += 1
        let gen = generation
        let settings = settings
        let input = inputPNGURL
        isConverting = true
        Task {
            let start = Date()
            do {
                let raw = try await runner.convert(inputURL: input, settings: settings)
                guard gen == generation else { return }
                rawSVG = raw
                // Shapes have new identities after a re-trace; stale per-shape
                // overrides and deletions would land on the wrong paths.
                selectedPathIndex = nil
                lassoSelection = []
                pathOverrides = [:]
                deletedPaths = []
                deletionStack = []
                await applyPostProcess(to: raw, generation: gen, conversionStart: start)
            } catch is CancellationError {
                // Superseded by a newer conversion; the newer one owns the UI state.
            } catch {
                guard gen == generation else { return }
                isConverting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Re-runs only the post-processing stage (simplification) on the cached
    /// raw vtracer output.
    private func schedulePostProcess() {
        guard let raw = rawSVG else { return }
        generation += 1
        let gen = generation
        postProcessDebounceTask?.cancel()
        postProcessDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.isConverting = true
            await self.applyPostProcess(to: raw, generation: gen, conversionStart: nil)
        }
    }

    /// Transforms applied to vtracer's raw SVG before it reaches the preview
    /// and export. Runs off the main actor; results are dropped if stale.
    private func applyPostProcess(to raw: String, generation gen: Int, conversionStart: Date?) async {
        let simplify = simplification
        let overrides = pathOverrides
        let deleted = deletedPaths
        let result = await Task.detached(priority: .userInitiated) {
            SVGSimplifier.process(raw, settings: simplify, overrides: overrides, deleted: deleted)
        }.value
        guard gen == generation else { return }
        svgText = result.svg
        pathCount = result.pathCount
        rawPointCount = result.inputPointCount
        pointCount = result.outputPointCount
        nodeCount = result.outputNodeCount
        if let conversionStart {
            lastConversionTime = Date().timeIntervalSince(conversionStart)
        }
        isConverting = false
        errorMessage = nil
    }
}
