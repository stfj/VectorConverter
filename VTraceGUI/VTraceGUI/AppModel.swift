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
    case anchor
    case hand
    case addBrush
    case subtractBrush

    var isBrush: Bool {
        self == .addBrush || self == .subtractBrush
    }
}

private nonisolated struct PendingBrushStroke: @unchecked Sendable {
    let pathIndex: Int
    let points: [CGPoint]
    let diameter: CGFloat
    let pathTransform: CGAffineTransform
    let operation: ShapeBrushOperation
}

@MainActor
@Observable
final class AppModel {
    var settings = VTracerSettings() {
        didSet { if settings != oldValue, !suppressPipeline { scheduleConversion() } }
    }

    /// AI upscaling (Upscayl, Digital Art model) applied to the source image
    /// before tracing; re-runs from the cached original on any change.
    var upscale = UpscaleSettings() {
        didSet { if upscale != oldValue, !suppressPipeline { prepareInput() } }
    }

    /// Post-processing applied on top of vtracer's output; re-runs on the
    /// cached raw SVG without invoking the CLI again.
    var simplification = SimplificationSettings() {
        didSet {
            if simplification != oldValue, !suppressPipeline {
                // Edited shapes re-simplify from their baked geometry, so point
                // edits persist; only the live anchor selection (indices into the
                // about-to-change display) is stale.
                selectedAnchors = []
                schedulePostProcess()
            }
        }
    }

    /// Active preview tool. The left palette and V/Z/W/A/H/B/E switch among
    /// selection, navigation, point editing, and the two shape brushes.
    private(set) var previewTool = PreviewTool.cursor {
        didSet { if previewTool != oldValue { selectedAnchors = [] } }
    }

    /// Diameter of both shape brushes, measured in source/SVG pixels.
    /// The preview turns this into a zoom-aware circular cursor.
    private(set) var brushSize = 32.0

    /// True while the space bar is held: temporary hand tool for panning,
    /// also hides the selected shape's control points.
    private(set) var spaceDown = false

    /// True while ⌥ is held (zoom tool shows the zoom-out cursor).
    private(set) var altDown = false
    /// Temporary Space-to-pan applies only while the preview owns keyboard
    /// focus, so Space can still activate a keyboard-focused native control.
    private(set) var previewHasKeyboardFocus = false

    /// Index (document order) of the shape selected by clicking in the preview.
    var selectedPathIndex: Int?

    /// Shapes selected by the magic wand lasso (W). Mutually exclusive with
    /// the single click-selection above.
    private(set) var lassoSelection: Set<Int> = []

    /// Anchor points selected with the point tool (A), as indices into the
    /// currently-displayed path of `selectedPathIndex` (i.e. after any prior
    /// point deletions). Reported from the preview; consumed on delete.
    private(set) var selectedAnchors: Set<Int> = []

    /// Per-shape baked geometry from the point tool, keyed by raw-SVG path
    /// index. When present it replaces the raw trace as the simplifier's input
    /// for that path, so deleted points survive (and re-simplify with) knob
    /// changes. Cleared only on re-trace, when raw shape identity changes.
    private(set) var editedGeometry: [Int: String] = [:]

    /// User-authored translations in root-SVG coordinates. These are applied
    /// after simplification instead of being baked into `editedGeometry`, so
    /// later geometry changes cannot shift the shape or compound its movement.
    private(set) var pathOffsets: [Int: ShapeOffset] = [:]

    /// Per-shape simplification settings, keyed by path index in the raw SVG.
    /// Cleared whenever vtracer re-runs, since shape identity changes.
    private(set) var pathOverrides: [Int: SimplificationSettings] = [:]

    /// Raw-SVG indices of shapes the user deleted. Cleared on re-trace.
    private(set) var deletedPaths: Set<Int> = []

    /// Reversible edit history for ⌘Z. A wand delete restores its whole group;
    /// point and brush edits restore geometry, and moves restore the prior
    /// separately-stored translation for one shape.
    private enum EditAction {
        case deleteShapes([Int])
        case changeGeometry(path: Int, previous: String?)
        case moveShape(path: Int, previous: ShapeOffset?)
    }
    private var undoStack: [EditAction] = []

    /// Bumped each time a new source image is loaded; the preview keys off this.
    private(set) var imageVersion = 0
    private(set) var sourcePixelSize: CGSize?
    /// Pixel size of the image as loaded, before any upscaling.
    private(set) var originalPixelSize: CGSize?
    private(set) var isUpscaling = false
    /// 0...1 while isUpscaling.
    private(set) var upscaleProgress = 0.0
    private(set) var svgText: String?
    private(set) var isPreviewReady = false
    private(set) var isConverting = false
    private(set) var isPostProcessPending = false
    private(set) var pathCount = 0
    private(set) var rawPointCount: Int?
    private(set) var pointCount: Int?
    private(set) var nodeCount: Int?
    /// Distinct fill colors in the raw trace; the Colors slider's upper bound.
    private(set) var colorCount = 0
    private(set) var outputColorCount = 0
    /// Palette after automatic OkLAB reduction, in first-appearance order.
    /// Manual grouping is exposed when this post-smash palette is small.
    private(set) var colorPalette: [PaletteColor] = []
    private var manualColorGroupRules: [ManualColorGroupRule] = []
    /// The palette group whose rendered regions are emphasized in the preview.
    /// This is presentation-only state and is intentionally not persisted.
    private(set) var highlightedColorGroupID: String?
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
    /// While true, the `settings`/`upscale`/`simplification` observers don't
    /// kick off the pipeline — used while restoring a saved design so a single
    /// post-process renders it instead of a re-trace per restored knob.
    private var suppressPipeline = false
    /// The `.vtrace` file backing the current design, if it came from / was
    /// saved to disk. ⌘S writes here; a new image clears it (untitled again).
    private(set) var currentDesignURL: URL?
    private let runner = VTracerRunner()
    private let upscaler = UpscaylRunner()
    private var upscaleTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var traceCancellationTask: Task<Void, Never>?
    private var postProcessDebounceTask: Task<Void, Never>?
    /// The in-flight off-main post-process; cancelled when a newer one starts so
    /// superseded heavy runs stop instead of stacking up across cores.
    private var postProcessWork: Task<SVGSimplifier.Result?, Never>?
    private var postProcessJobID = 0
    /// Brush booleans can be expensive for detailed traces. Gestures are queued
    /// in input order and calculated off the main actor so the UI stays live.
    private var pendingBrushStrokes: [PendingBrushStroke] = []
    private var activeBrushStroke: PendingBrushStroke?
    private var brushWork: Task<String?, Never>?
    private var brushSessionGeneration: Int?
    private var brushJobID = 0
    /// Incremented when pending brush feedback must be cleared in the preview.
    private(set) var brushFeedbackVersion = 0
    private var postProcessRequestedAfterBrush = false
    /// The vtracer generation currently producing a replacement raw SVG.
    /// Brush interaction is visibly disabled while a replacement trace is
    /// pending or running, since its new path identities cannot safely accept
    /// strokes aimed at the old trace.
    private var traceGeneration: Int?
    private var traceRequestID = 0
    private var activeTraceRequestID: Int?
    private var traceWaitingForBrushRequestID: Int?
    private var postProcessRequestedAfterTrace = false
    private(set) var isTracePending = false
    /// Changes whenever a new image, design, or raw trace owns path indices.
    private(set) var previewRevision = 0
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
        guard NSApp.modalWindow == nil,
              let window = event.window,
              !(window is NSPanel) else { return event }
        if window.firstResponder is NSTextView { return event }

        // Tool switching and brush sizing. No command/option/control modifiers,
        // so app shortcuts such as ⌘Z and ⌘E keep their normal meanings.
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "z": selectTool(.zoom)
            case "v": selectTool(.cursor)
            case "w": selectTool(.wand)
            case "a": selectTool(.anchor)
            case "h": selectTool(.hand)
            case "b":
                if !event.isARepeat {
                    if previewTool == .addBrush {
                        selectTool(.subtractBrush)
                    } else if previewTool == .subtractBrush {
                        selectTool(.addBrush)
                    } else {
                        selectTool(.addBrush)
                    }
                }
            case "e": selectTool(.subtractBrush)
            case "[": adjustBrushSize(growing: false)
            case "]": adjustBrushSize(growing: true)
            default: break
            }
            if ["z", "v", "w", "a", "h", "b", "e", "[", "]"].contains(key) {
                return nil
            }
        }

        // ⌘C / ⌘V: handle here because the preview WKWebView becomes first
        // responder when clicked and swallows these key equivalents before
        // the menu bar sees them.
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command],
           let key = event.charactersIgnoringModifiers?.lowercased() {
            if key == "c", canExportSVG {
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
            guard previewHasKeyboardFocus else { return event }
            if event.type == .keyDown {
                if !event.isARepeat { spaceDown = true }
            } else {
                spaceDown = false
            }
            return nil
        case 51, 117: // backspace, forward delete
            guard event.type == .keyDown else { return event }
            if previewTool == .anchor, selectedPathIndex != nil, !selectedAnchors.isEmpty {
                deleteSelectedAnchors()
                return nil
            }
            if selectedPathIndex != nil || !lassoSelection.isEmpty {
                deleteSelectedShape()
                return nil
            }
            return event
        default:
            return event
        }
    }

    /// Deletes the wand selection if there is one, else the clicked shape.
    func deleteSelectedShape() {
        guard editingInteractionEnabled else {
            errorMessage = "Wait for the current image update before editing shapes."
            return
        }
        guard !isBrushProcessing else {
            errorMessage = "Wait for the brush stroke to finish before deleting a shape."
            return
        }
        if !lassoSelection.isEmpty {
            let group = lassoSelection.sorted()
            deletedPaths.formUnion(group)
            undoStack.append(.deleteShapes(group))
            lassoSelection = []
            schedulePostProcess()
            return
        }
        guard let index = selectedPathIndex else { return }
        deletedPaths.insert(index)
        undoStack.append(.deleteShapes([index]))
        selectedPathIndex = nil
        schedulePostProcess()
    }

    /// Removes the anchor points selected with the point tool from the selected
    /// shape, keeping it a continuous (still-closed) shape. The result is baked
    /// as the shape's geometry, so it survives — and re-simplifies with — later
    /// knob changes. Indices are into the currently-displayed path, so removal
    /// is applied to exactly what the user clicked.
    func deleteSelectedAnchors() {
        guard editingInteractionEnabled else {
            errorMessage = "Wait for the current image update before editing points."
            return
        }
        guard !isBrushProcessing else {
            errorMessage = "Wait for the brush stroke to finish before editing points."
            return
        }
        guard let shape = selectedPathIndex, !selectedAnchors.isEmpty,
              let displayed = currentPathD(shape) else { selectedAnchors = []; return }
        let edited = SVGSimplifier.removeAnchors(displayed, selectedAnchors)
        selectedAnchors = []
        guard edited != displayed else { return }
        undoStack.append(.changeGeometry(path: shape, previous: editedGeometry[shape]))
        editedGeometry[shape] = edited
        schedulePostProcess()
    }

    /// The `d` attribute of the index-th path in the current output SVG (the
    /// geometry the preview is showing and the user is clicking anchors on).
    private func currentPathD(_ index: Int) -> String? {
        guard let svgText else { return nil }
        let ns = svgText as NSString
        let regex = try! NSRegularExpression(pattern: "d=\"([^\"]*)\"")
        let matches = regex.matches(in: svgText, range: NSRange(location: 0, length: ns.length))
        guard index >= 0, index < matches.count else { return nil }
        return ns.substring(with: matches[index].range(at: 1))
    }

    /// Immediately mirrors a baked edit into the displayed SVG. The normal
    /// post-process still follows, but this makes brush feedback instant and
    /// ensures another fast stroke starts from the geometry the user can see.
    private func replaceCurrentPathD(_ index: Int, with d: String) {
        guard let svgText else { return }
        let ns = svgText as NSString
        let regex = try! NSRegularExpression(pattern: "d=\"([^\"]*)\"")
        let matches = regex.matches(in: svgText, range: NSRange(location: 0, length: ns.length))
        guard index >= 0, index < matches.count else { return }
        let output = NSMutableString(string: svgText)
        output.replaceCharacters(in: matches[index].range(at: 1), with: d)
        self.svgText = output as String
    }

    func setSelectedAnchors(_ indices: Set<Int>) {
        selectedAnchors = indices
    }

    func setPreviewKeyboardFocus(_ focused: Bool) {
        previewHasKeyboardFocus = focused
        if !focused { spaceDown = false }
    }

    var isBrushProcessing: Bool {
        activeBrushStroke != nil || brushWork != nil || !pendingBrushStrokes.isEmpty
    }

    var editingInteractionEnabled: Bool {
        isPreviewReady && !isUpscaling && !isTracePending
    }

    var brushInteractionEnabled: Bool { editingInteractionEnabled }
    var shapeMoveInteractionEnabled: Bool {
        editingInteractionEnabled &&
            !isBrushProcessing &&
            !isPostProcessPending &&
            !isConverting
    }

    var canUndoDeletion: Bool {
        isBrushProcessing || (editingInteractionEnabled && !undoStack.isEmpty)
    }

    func undoLastEdit() {
        // A submitted brush gesture is already the newest user transaction,
        // even while its boolean operation is still running. Undo that gesture
        // alone instead of also popping the previously committed edit.
        if undoNewestPendingBrushStroke() { return }

        guard editingInteractionEnabled else {
            errorMessage = "Wait for the current image update before undoing an edit."
            return
        }
        guard let action = undoStack.popLast() else { return }
        switch action {
        case .deleteShapes(let group):
            deletedPaths.subtract(group)
            if group.count == 1 {
                selectedPathIndex = group[0]
                lassoSelection = []
            } else {
                setLassoSelection(Set(group))
            }
        case .changeGeometry(let path, let previous):
            editedGeometry[path] = previous
            selectPath(path)
        case .moveShape(let path, let previous):
            pathOffsets[path] = previous
            selectPath(path)
        }
        schedulePostProcess()
    }

    /// Cancels exactly the newest uncommitted gesture. Later queued gestures
    /// are removed first; the active background job is cancelled only when it
    /// is itself newest. Core Graphics work is non-cooperative, so the job ID
    /// also prevents a late result from committing.
    @discardableResult
    private func undoNewestPendingBrushStroke() -> Bool {
        if !pendingBrushStrokes.isEmpty {
            pendingBrushStrokes.removeLast()
            brushFeedbackVersion += 1
            return true
        }
        guard brushWork != nil else { return false }

        brushWork?.cancel()
        brushWork = nil
        activeBrushStroke = nil
        brushJobID += 1
        brushFeedbackVersion += 1
        if let sessionGeneration = brushSessionGeneration {
            finishBrushSession(generation: sessionGeneration)
        }
        return true
    }

    // MARK: - Preview tools

    func selectTool(_ tool: PreviewTool) {
        previewTool = tool
    }

    func adjustBrushSize(growing: Bool) {
        let proposed = growing ? ceil(brushSize * 1.2) : floor(brushSize / 1.2)
        let stepped: Double
        if proposed == brushSize {
            stepped = brushSize + (growing ? 1 : -1)
        } else {
            stepped = proposed
        }
        brushSize = stepped
        clampBrushSizeToCanvas()
    }

    private func clampBrushSizeToCanvas() {
        let imageLimit = sourcePixelSize.map {
            max(Double($0.width), Double($0.height))
        } ?? 512
        brushSize = min(max(imageLimit, 512), max(1, brushSize))
    }

    /// Queues one completed round brush gesture. Each gesture remains a single
    /// undo step, but parsing and Core Graphics boolean work happen off-main.
    /// A session uses one stable preview generation and serial ordering, so
    /// rapid add/subtract gestures cannot overwrite each other out of order.
    func applyBrushStroke(to pathIndex: Int,
                          points: [CGPoint],
                          diameter: Double,
                          pathTransform: CGAffineTransform,
                          operation: ShapeBrushOperation,
                          previewRevision messageRevision: Int) {
        guard selectedPathIndex == pathIndex,
              !lassoSelection.contains(pathIndex),
              !points.isEmpty,
              brushInteractionEnabled,
              messageRevision == previewRevision else {
            brushFeedbackVersion += 1
            return
        }

        let wasIdle = brushWork == nil && pendingBrushStrokes.isEmpty
        if wasIdle {
            // Any older post-process can be reproduced from rawSVG after this
            // session. Invalidating it prevents an old result from replacing a
            // newly painted preview while the boolean calculation is running.
            postProcessDebounceTask?.cancel()
            postProcessDebounceTask = nil
            postProcessWork?.cancel()
            postProcessWork = nil
            postProcessJobID += 1
            isPostProcessPending = false
            generation += 1
            brushSessionGeneration = generation
            postProcessRequestedAfterBrush = false
            isConverting = false
        }

        pendingBrushStrokes.append(PendingBrushStroke(
            pathIndex: pathIndex,
            points: points,
            diameter: CGFloat(diameter),
            pathTransform: pathTransform,
            operation: operation
        ))
        startNextBrushStroke()
    }

    private func startNextBrushStroke() {
        guard brushWork == nil,
              let sessionGeneration = brushSessionGeneration,
              sessionGeneration == generation else {
            if brushSessionGeneration != generation {
                cancelBrushWork()
            }
            return
        }

        while !pendingBrushStrokes.isEmpty {
            let request = pendingBrushStrokes.removeFirst()
            guard !deletedPaths.contains(request.pathIndex),
                  let base = currentPathD(request.pathIndex) else {
                continue
            }

            activeBrushStroke = request
            brushJobID += 1
            let jobID = brushJobID
            let work = Task.detached(priority: .userInitiated) { () -> String? in
                guard !Task.isCancelled else { return nil }
                return ShapeBrushGeometry.apply(
                    to: base,
                    points: request.points,
                    diameter: request.diameter,
                    pathTransform: request.pathTransform,
                    operation: request.operation
                )
            }
            brushWork = work
            Task { [weak self] in
                let edited = await work.value
                guard let self else { return }
                self.finishBrushStroke(
                    request,
                    base: base,
                    edited: edited,
                    sessionGeneration: sessionGeneration,
                    jobID: jobID
                )
            }
            return
        }

        finishBrushSession(generation: sessionGeneration)
    }

    private func finishBrushStroke(_ request: PendingBrushStroke,
                                   base: String,
                                   edited: String?,
                                   sessionGeneration: Int,
                                   jobID: Int) {
        guard jobID == brushJobID else { return }
        brushWork = nil
        activeBrushStroke = nil

        guard sessionGeneration == generation,
              currentPathD(request.pathIndex) == base else {
            cancelBrushWork()
            return
        }
        guard let edited else {
            errorMessage = "That shape could not be edited with the brush."
            pendingBrushStrokes = []
            brushFeedbackVersion += 1
            finishBrushSession(generation: sessionGeneration)
            return
        }

        if edited != base {
            selectedAnchors = []
            undoStack.append(.changeGeometry(
                path: request.pathIndex,
                previous: editedGeometry[request.pathIndex]
            ))
            editedGeometry[request.pathIndex] = edited
            replaceCurrentPathD(request.pathIndex, with: edited)
        }
        brushFeedbackVersion += 1
        startNextBrushStroke()
    }

    private func finishBrushSession(generation sessionGeneration: Int) {
        guard brushWork == nil else { return }
        brushSessionGeneration = nil
        guard sessionGeneration == generation else {
            pendingBrushStrokes = []
            return
        }
        postProcessRequestedAfterBrush = false

        // A tracer-settings change may have reached the end of its debounce
        // while this stroke was committing. Give that replacement trace
        // priority; it will post-process with every latest setting.
        if traceWaitingForBrushRequestID == traceRequestID {
            let requestID = traceRequestID
            traceWaitingForBrushRequestID = nil
            startConversion(requestID: requestID)
            return
        }
        if isTracePending { return }

        // Also restores any older post-process that was cancelled when the
        // brush session began, even if every gesture was a geometric no-op.
        schedulePostProcess()
    }

    private func cancelBrushWork() {
        brushWork?.cancel()
        brushWork = nil
        activeBrushStroke = nil
        pendingBrushStrokes = []
        brushSessionGeneration = nil
        brushJobID += 1
        brushFeedbackVersion += 1
        postProcessRequestedAfterBrush = false
    }

    // MARK: - Manual color groups

    var canShowManualColorPanel: Bool {
        !colorPalette.isEmpty && colorPalette.count < 32
    }

    /// Presentation groups include unedited singleton colors alongside the
    /// compact rules that actually need to be persisted.
    var manualColorGroups: [ManualColorGroup] {
        let paletteByHex = Dictionary(
            uniqueKeysWithValues: colorPalette.map { ($0.hex, $0) }
        )
        var ruleByMember: [String: ManualColorGroupRule] = [:]
        for rule in manualColorGroupRules {
            for member in rule.members where ruleByMember[member] == nil {
                ruleByMember[member] = rule
            }
        }

        var visited: Set<String> = []
        var groups: [ManualColorGroup] = []
        for color in colorPalette where !visited.contains(color.hex) {
            guard let rule = ruleByMember[color.hex] else {
                visited.insert(color.hex)
                groups.append(ManualColorGroup(
                    id: color.hex,
                    colorHex: color.hex,
                    members: [color]
                ))
                continue
            }

            let members = rule.members.compactMap { paletteByHex[$0] }
            guard let first = members.first else { continue }
            visited.formUnion(members.map(\.hex))
            groups.append(ManualColorGroup(
                id: first.hex,
                colorHex: PaletteHex.normalize(rule.colorHex) ?? first.hex,
                members: members
            ))
        }
        return groups
    }

    /// The final, post-grouping fill shown by the selected palette group.
    /// The preview matches this against its rendered paths, so every visible
    /// region with that color is highlighted together.
    var highlightedColorHex: String? {
        guard let highlightedColorGroupID else { return nil }
        return manualColorGroups.first {
            $0.id == highlightedColorGroupID
        }?.colorHex
    }

    func setColorHighlight(groupID: String) {
        guard let groupID = PaletteHex.normalize(groupID),
              manualColorGroups.contains(where: { $0.id == groupID }) else {
            return
        }
        highlightedColorGroupID = groupID
    }

    func clearColorHighlight() {
        highlightedColorGroupID = nil
    }

    /// A delayed exit from one tile must not clear a newer neighboring hover.
    func clearColorHighlight(groupID: String) {
        guard let groupID = PaletteHex.normalize(groupID),
              highlightedColorGroupID == groupID else { return }
        highlightedColorGroupID = nil
    }

    /// Merges the entire source group into the destination group. Single
    /// member moves use `moveColorMember` below.
    func group(sourceHex: String, ontoTargetHex targetHex: String) {
        guard editingInteractionEnabled,
              canShowManualColorPanel,
              let source = PaletteHex.normalize(sourceHex),
              let target = PaletteHex.normalize(targetHex),
              let sourceGroup = manualColorGroups.first(where: {
                  $0.members.contains(where: { $0.hex == source })
              }),
              let targetGroup = manualColorGroups.first(where: {
                  $0.members.contains(where: { $0.hex == target })
              }),
              sourceGroup.id != targetGroup.id else { return }

        // Palette emphasis is hover-only. A completed drag ends that hover
        // preview rather than transferring sticky highlight ownership.
        highlightedColorGroupID = nil
        let targetMembers = targetGroup.members.map(\.hex)
        let sourceMembers = sourceGroup.members.map(\.hex)
        let touched = Set(targetMembers + sourceMembers)
        manualColorGroupRules.removeAll {
            !$0.members.allSatisfy { !touched.contains($0) }
        }
        manualColorGroupRules.append(ManualColorGroupRule(
            members: targetMembers + sourceMembers.filter { !targetMembers.contains($0) },
            colorHex: targetGroup.colorHex
        ))
        finishManualColorChange()
    }

    /// Moves exactly one post-smash color into a destination group as a
    /// single model mutation. This avoids briefly publishing an ungrouped
    /// intermediate state (and scheduling two post-process passes).
    @discardableResult
    func moveColorMember(_ sourceHex: String,
                         ontoTargetHex targetHex: String) -> Bool {
        guard editingInteractionEnabled,
              canShowManualColorPanel,
              let source = PaletteHex.normalize(sourceHex),
              let target = PaletteHex.normalize(targetHex),
              let sourceGroup = manualColorGroups.first(where: {
                  $0.members.contains(where: { $0.hex == source })
              }),
              let targetGroup = manualColorGroups.first(where: {
                  $0.members.contains(where: { $0.hex == target })
              }),
              sourceGroup.id != targetGroup.id else {
            return false
        }

        highlightedColorGroupID = nil
        let sourceMembers = sourceGroup.members.map(\.hex)
        let targetMembers = targetGroup.members.map(\.hex)
        let touched = Set(sourceMembers + targetMembers)
        manualColorGroupRules.removeAll {
            !$0.members.allSatisfy { !touched.contains($0) }
        }

        let remaining = sourceMembers.filter { $0 != source }
        if let first = remaining.first {
            let wasCustom = sourceGroup.colorHex != sourceGroup.id
            let remainingColor = wasCustom ? sourceGroup.colorHex : first
            if remaining.count > 1 || remainingColor != first {
                manualColorGroupRules.append(ManualColorGroupRule(
                    members: remaining,
                    colorHex: remainingColor
                ))
            }
        }

        manualColorGroupRules.append(ManualColorGroupRule(
            members: targetMembers + [source],
            colorHex: targetGroup.colorHex
        ))
        finishManualColorChange()
        return true
    }

    /// Extracts one post-smash color from its group. The remaining group's first
    /// member becomes its representative; a genuinely custom output survives.
    func ungroup(hex: String) {
        guard editingInteractionEnabled,
              canShowManualColorPanel,
              let hex = PaletteHex.normalize(hex),
              let group = manualColorGroups.first(where: {
                  $0.members.contains(where: { $0.hex == hex })
              }) else { return }

        highlightedColorGroupID = nil
        let memberHexes = group.members.map(\.hex)
        let wasCustom = group.colorHex != group.id
        guard memberHexes.count > 1 || wasCustom else { return }

        let touched = Set(memberHexes)
        manualColorGroupRules.removeAll {
            !$0.members.allSatisfy { !touched.contains($0) }
        }

        let remaining = memberHexes.filter { $0 != hex }
        if let first = remaining.first {
            let remainingColor = wasCustom ? group.colorHex : first
            if remaining.count > 1 || remainingColor != first {
                manualColorGroupRules.append(ManualColorGroupRule(
                    members: remaining,
                    colorHex: remainingColor
                ))
            }
        }
        finishManualColorChange()
    }

    func setGroupColor(groupID: String, hex: String) {
        guard editingInteractionEnabled,
              canShowManualColorPanel,
              let groupID = PaletteHex.normalize(groupID),
              let output = PaletteHex.normalize(hex),
              let group = manualColorGroups.first(where: { $0.id == groupID }),
              output != group.colorHex else { return }

        highlightedColorGroupID = nil
        let members = group.members.map(\.hex)
        let touched = Set(members)
        manualColorGroupRules.removeAll {
            !$0.members.allSatisfy { !touched.contains($0) }
        }
        if members.count > 1 || output != group.id {
            manualColorGroupRules.append(ManualColorGroupRule(
                members: members,
                colorHex: output
            ))
        }
        finishManualColorChange()
    }

    /// Manual grouping runs after the automatic OkLAB reduction, so direct
    /// edits keep the current slider budget and are applied to its resulting
    /// post-smash palette.
    private func finishManualColorChange() {
        schedulePostProcess()
    }

    private var manualColorMapping: [String: String] {
        var mapping: [String: String] = [:]
        for rule in manualColorGroupRules {
            guard let output = PaletteHex.normalize(rule.colorHex) else { continue }
            for member in rule.members {
                if let member = PaletteHex.normalize(member),
                   mapping[member] == nil {
                    mapping[member] = output
                }
            }
        }
        return mapping
    }

    private func sanitizeManualColorGroups() {
        let allowed = Set(colorPalette.map(\.hex))
        var claimed: Set<String> = []
        var sanitized: [ManualColorGroupRule] = []

        for rule in manualColorGroupRules {
            var members: [String] = []
            for rawMember in rule.members {
                guard let member = PaletteHex.normalize(rawMember),
                      allowed.contains(member),
                      claimed.insert(member).inserted else { continue }
                members.append(member)
            }
            guard let first = members.first else { continue }
            let output = PaletteHex.normalize(rule.colorHex) ?? first
            if members.count > 1 || output != first {
                sanitized.append(ManualColorGroupRule(
                    members: members,
                    colorHex: output
                ))
            }
        }
        manualColorGroupRules = sanitized
        if !canShowManualColorPanel {
            highlightedColorGroupID = nil
        } else if let highlightedColorGroupID,
                  !manualColorGroups.contains(where: { $0.id == highlightedColorGroupID }) {
            self.highlightedColorGroupID = nil
        }
    }

    // MARK: - Selection

    /// Single click-selection from the preview; replaces any wand selection.
    func selectPath(_ index: Int?) {
        selectedPathIndex = index
        lassoSelection = []
        selectedAnchors = []
    }

    func setLassoSelection(_ indices: Set<Int>) {
        lassoSelection = indices
        if !indices.isEmpty { selectedPathIndex = nil }
    }

    /// Commits one cursor-tool drag as a root-SVG translation. The preview
    /// applies the same delta live; the post-process then rebuilds the SVG from
    /// the untouched path geometry plus this stored offset.
    func movePath(_ index: Int,
                  byX deltaX: Double,
                  y deltaY: Double,
                  previewRevision messageRevision: Int) {
        guard messageRevision == previewRevision,
              shapeMoveInteractionEnabled,
              index >= 0, index < pathCount,
              !deletedPaths.contains(index),
              deltaX.isFinite, deltaY.isFinite,
              abs(deltaX) > 1e-9 || abs(deltaY) > 1e-9 else { return }

        let previous = pathOffsets[index]
        let current = previous ?? .zero
        let next = ShapeOffset(x: current.x + deltaX, y: current.y + deltaY)
        guard next.x.isFinite, next.y.isFinite else { return }

        undoStack.append(.moveShape(path: index, previous: previous))
        if abs(next.x) <= 1e-9 && abs(next.y) <= 1e-9 {
            pathOffsets.removeValue(forKey: index)
        } else {
            pathOffsets[index] = next
        }
        selectPath(index)
        schedulePostProcess()
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
        clampBrushSizeToCanvas()
        hasImage = true
        svgText = nil
        isPreviewReady = false
        rawSVG = nil
        pathCount = 0
        rawPointCount = nil
        pointCount = nil
        nodeCount = nil
        colorCount = 0
        outputColorCount = 0
        colorPalette = []
        manualColorGroupRules = []
        highlightedColorGroupID = nil
        lastConversionTime = nil
        errorMessage = nil
        selectedPathIndex = nil
        lassoSelection = []
        selectedAnchors = []
        pathOverrides = [:]
        editedGeometry = [:]
        pathOffsets = [:]
        deletedPaths = []
        undoStack = []
        currentDesignURL = nil
        previewRevision += 1
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
        guard canExportSVG, let svgText else { return }
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
        guard canExportSVG, let svgText else { return }
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

    // MARK: - Design files (save / load a .vtrace for later tweaking)

    /// A design can be saved once there's a trace to preserve.
    var canExportSVG: Bool {
        svgText != nil &&
            !isBrushProcessing &&
            !isUpscaling &&
            !isTracePending &&
            !isPostProcessPending &&
            !isConverting
    }

    var canSaveDesign: Bool {
        canExportSVG && hasImage
    }

    /// ⌘S: write back to the open file, or prompt if this design is untitled.
    func saveDesign() {
        guard canSaveDesign else { return }
        if let url = currentDesignURL {
            writeDesign(to: url)
        } else {
            saveDesignAs()
        }
    }

    /// Always prompts for a location (⇧⌘S, or first save of an untitled design).
    func saveDesignAs() {
        guard canSaveDesign else { return }
        let panel = NSSavePanel()
        if let type = VTraceDocument.utType { panel.allowedContentTypes = [type] }
        panel.nameFieldStringValue = sourceName + "." + VTraceDocument.fileExtension
        if panel.runModal() == .OK, let url = panel.url {
            writeDesign(to: url)
            currentDesignURL = url
        }
    }

    private func writeDesign(to url: URL) {
        guard canSaveDesign, let document = buildDocument() else { return }
        do {
            try document.encoded().write(to: url, options: .atomic)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save design: \(error.localizedDescription)"
        }
    }

    /// Snapshots everything needed to reopen and keep tweaking: the source +
    /// traced PNGs, vtracer's raw SVG, and all settings/edits.
    private func buildDocument() -> VTraceDocument? {
        guard let rawSVG, hasImage,
              let originalData = try? Data(contentsOf: originalPNGURL),
              let inputData = try? Data(contentsOf: inputPNGURL) else { return nil }
        let original = originalPixelSize ?? .zero
        let input = sourcePixelSize ?? original
        return VTraceDocument(
            sourceName: sourceName,
            originalPNG: originalData,
            inputPNG: inputData,
            rawSVG: rawSVG,
            settings: settings,
            upscale: upscale,
            simplification: simplification,
            pathOverrides: pathOverrides,
            editedGeometry: editedGeometry,
            deletedPaths: deletedPaths.sorted(),
            pathOffsets: pathOffsets,
            manualColorGroupRules: manualColorGroupRules,
            originalPixelWidth: Int(original.width),
            originalPixelHeight: Int(original.height),
            inputPixelWidth: Int(input.width),
            inputPixelHeight: Int(input.height)
        )
    }

    func openDesignPanel() {
        let panel = NSOpenPanel()
        if let type = VTraceDocument.utType { panel.allowedContentTypes = [type] }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            loadDesign(from: url)
        }
    }

    /// Restores a saved design and renders it — post-process only, so it loads
    /// instantly with no re-trace or re-upscale, and the per-shape edits land
    /// on the exact path indices they were made against. The source image is
    /// restored too, so changing vtracer/upscale settings still works.
    func loadDesign(from url: URL) {
        let document: VTraceDocument
        do {
            document = try VTraceDocument.decoded(from: Data(contentsOf: url))
        } catch {
            errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }

        // Stop anything in flight; the loaded design owns the UI state now.
        upscaleTask?.cancel()
        upscaleTask = nil
        inputGeneration += 1
        postProcessDebounceTask?.cancel()
        postProcessWork?.cancel()
        cancelBrushWork()
        invalidateTracePipeline()
        Task { [upscaler] in await upscaler.cancel() }

        do {
            try document.originalPNG.write(to: originalPNGURL)
            try document.inputPNG.write(to: inputPNGURL)
        } catch {
            errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }

        // Restore the knobs without retriggering the pipeline; one explicit
        // post-process below renders the whole thing.
        suppressPipeline = true
        settings = document.settings
        upscale = document.upscale
        simplification = document.simplification
        suppressPipeline = false

        rawSVG = document.rawSVG
        svgText = nil
        isPreviewReady = false
        pathCount = 0
        rawPointCount = nil
        pointCount = nil
        nodeCount = nil
        colorCount = 0
        outputColorCount = 0
        pathOverrides = document.pathOverrides
        editedGeometry = document.editedGeometry
        pathOffsets = (document.pathOffsets ?? [:]).filter {
            $0.key >= 0 && $0.value.x.isFinite && $0.value.y.isFinite
        }
        deletedPaths = Set(document.deletedPaths)
        manualColorGroupRules = document.manualColorGroupRules ?? []
        colorPalette = []
        highlightedColorGroupID = nil
        undoStack = []
        selectedPathIndex = nil
        lassoSelection = []
        selectedAnchors = []

        sourceName = document.sourceName
        originalPixelSize = CGSize(width: document.originalPixelWidth, height: document.originalPixelHeight)
        sourcePixelSize = CGSize(width: document.inputPixelWidth, height: document.inputPixelHeight)
        clampBrushSizeToCanvas()
        hasImage = true
        isUpscaling = false
        upscaleProgress = 0
        currentDesignURL = url
        errorMessage = nil
        previewRevision += 1
        imageVersion += 1

        // Re-derive the preview from the restored raw SVG (no CLI, no upscale).
        generation += 1
        let gen = generation
        let raw = document.rawSVG
        isConverting = true
        Task { await applyPostProcess(to: raw, generation: gen, conversionStart: nil) }
    }

    // MARK: - Per-shape overrides

    /// The settings currently in effect for a shape (its override, else global).
    func effectiveSimplification(for index: Int) -> SimplificationSettings {
        pathOverrides[index] ?? simplification
    }

    func setOverride(_ settings: SimplificationSettings, for index: Int) {
        guard editingInteractionEnabled else {
            errorMessage = "Wait for the current image update before editing a shape."
            return
        }
        pathOverrides[index] = settings
        // The shape re-simplifies from its baked geometry, so point edits hold;
        // only the live anchor selection (stale indices) is dropped.
        if selectedPathIndex == index { selectedAnchors = [] }
        schedulePostProcess()
    }

    func clearOverride(for index: Int) {
        guard editingInteractionEnabled else {
            errorMessage = "Wait for the current image update before editing a shape."
            return
        }
        guard pathOverrides.removeValue(forKey: index) != nil else { return }
        if selectedPathIndex == index { selectedAnchors = [] }
        schedulePostProcess()
    }

    // MARK: - Upscaling

    private func queueTraceCancellation() {
        let prior = traceCancellationTask
        traceCancellationTask = Task { [runner] in
            await prior?.value
            await runner.cancel()
        }
    }

    /// Invalidates every trace request belonging to the previous input/design.
    /// The request token prevents a terminating old process from clearing the
    /// pending state of a newer request.
    private func invalidateTracePipeline() {
        debounceTask?.cancel()
        debounceTask = nil
        postProcessDebounceTask?.cancel()
        postProcessDebounceTask = nil
        postProcessWork?.cancel()
        postProcessWork = nil
        postProcessJobID += 1
        isPostProcessPending = false
        traceRequestID += 1
        activeTraceRequestID = nil
        traceWaitingForBrushRequestID = nil
        traceGeneration = nil
        isTracePending = false
        postProcessRequestedAfterTrace = false
        generation += 1
        isConverting = false
        queueTraceCancellation()
    }

    /// Rebuilds input.png from the cached original — upscaled when enabled,
    /// a straight copy otherwise — then kicks off a fresh trace.
    private func prepareInput() {
        guard hasImage else { return }
        cancelBrushWork()
        upscaleTask?.cancel()
        // Invalidate any in-flight conversion; it traced the old input.
        invalidateTracePipeline()
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
            clampBrushSizeToCanvas()
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
                    self.clampBrushSizeToCanvas()
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

        traceRequestID += 1
        let requestID = traceRequestID
        isTracePending = true
        traceWaitingForBrushRequestID = nil
        postProcessRequestedAfterTrace = false

        // A replacement trace supersedes any old trace/post-process. Preserve
        // an active brush session's generation until its submitted gesture has
        // committed; the trace waits for that short transaction below.
        postProcessDebounceTask?.cancel()
        postProcessDebounceTask = nil
        postProcessWork?.cancel()
        postProcessWork = nil
        postProcessJobID += 1
        isPostProcessPending = false
        if !isBrushProcessing {
            generation += 1
        }
        isConverting = true

        // End a now-obsolete CLI process during the debounce. The replacement
        // awaits this ordered cancellation before starting, so a late cancel
        // can never terminate the new process.
        queueTraceCancellation()

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, !Task.isCancelled,
                  requestID == self.traceRequestID else { return }
            self.startConversion(requestID: requestID)
        }
    }

    private func startConversion(requestID: Int) {
        guard requestID == traceRequestID else { return }
        debounceTask = nil
        if isBrushProcessing {
            traceWaitingForBrushRequestID = requestID
            return
        }

        traceWaitingForBrushRequestID = nil
        generation += 1
        let gen = generation
        traceGeneration = gen
        activeTraceRequestID = requestID
        let cancellation = traceCancellationTask
        traceCancellationTask = nil
        let settings = settings
        let input = inputPNGURL
        isConverting = true
        Task {
            let start = Date()
            do {
                await cancellation?.value
                guard requestID == traceRequestID, gen == generation else { return }
                let raw = try await runner.convert(inputURL: input, settings: settings)
                guard requestID == traceRequestID, gen == generation else { return }
                rawSVG = raw
                isPreviewReady = false
                // Shapes have new identities after a re-trace; stale per-shape
                // overrides and deletions would land on the wrong paths.
                selectedPathIndex = nil
                lassoSelection = []
                selectedAnchors = []
                pathOverrides = [:]
                editedGeometry = [:]
                pathOffsets = [:]
                deletedPaths = []
                colorPalette = []
                highlightedColorGroupID = nil
                undoStack = []
                previewRevision += 1
                await applyPostProcess(to: raw, generation: gen, conversionStart: start)
                guard requestID == traceRequestID, gen == generation else { return }
                finishTrace(requestID: requestID, generation: gen, succeeded: true)
            } catch is CancellationError {
                // Superseded by a newer conversion; the newer one owns the UI state.
                finishTrace(requestID: requestID, generation: gen, succeeded: false)
            } catch {
                guard requestID == traceRequestID, gen == generation else { return }
                isConverting = false
                errorMessage = error.localizedDescription
                finishTrace(requestID: requestID, generation: gen, succeeded: false)
            }
        }
    }

    private func finishTrace(requestID: Int, generation gen: Int, succeeded: Bool) {
        guard activeTraceRequestID == requestID else { return }
        activeTraceRequestID = nil
        if traceGeneration == gen { traceGeneration = nil }

        // A newer debounced request still owns the busy/disabled state.
        guard requestID == traceRequestID else { return }
        isTracePending = false
        isConverting = false

        let needsFollowUp = postProcessRequestedAfterTrace &&
            (succeeded || rawSVG != nil)
        let preservedError = succeeded ? nil : errorMessage
        postProcessRequestedAfterTrace = false
        if needsFollowUp {
            schedulePostProcess(preservingError: preservedError)
        }
    }

    /// Re-runs only the post-processing stage (simplification) on the cached
    /// raw vtracer output.
    private func schedulePostProcess(preservingError: String? = nil) {
        guard let raw = rawSVG else { return }
        if isBrushProcessing {
            postProcessRequestedAfterBrush = true
            return
        }
        if isUpscaling || isTracePending {
            postProcessRequestedAfterTrace = true
            return
        }

        generation += 1
        let gen = generation
        postProcessDebounceTask?.cancel()
        postProcessWork?.cancel()
        postProcessWork = nil
        postProcessJobID += 1
        isPostProcessPending = true
        isConverting = true
        postProcessDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.postProcessDebounceTask = nil
            await self.applyPostProcess(
                to: raw,
                generation: gen,
                conversionStart: nil,
                preservingError: preservingError
            )
        }
    }

    /// Transforms applied to vtracer's raw SVG before it reaches the preview
    /// and export. Runs off the main actor; results are dropped if stale.
    private func applyPostProcess(to raw: String,
                                  generation gen: Int,
                                  conversionStart: Date?,
                                  preservingError: String? = nil) async {
        // Stop any earlier computation that this one supersedes.
        postProcessWork?.cancel()
        postProcessJobID += 1
        let jobID = postProcessJobID
        isPostProcessPending = true
        isConverting = true
        let simplify = simplification
        let overrides = pathOverrides
        let deleted = deletedPaths
        let edited = editedGeometry
        let offsets = pathOffsets
        let manualColors = manualColorMapping
        let work = Task.detached(priority: .userInitiated) {
            SVGSimplifier.process(raw, settings: simplify, overrides: overrides,
                                  deleted: deleted, editedGeometry: edited,
                                  shapeOffsets: offsets,
                                  manualColors: manualColors)
        }
        postProcessWork = work
        let result = await work.value
        // nil → this run was cancelled by a newer one, which owns the UI state.
        guard jobID == postProcessJobID else { return }
        postProcessWork = nil
        guard let result, gen == generation else {
            if gen == generation {
                isPostProcessPending = false
                isConverting = false
            }
            return
        }
        svgText = result.svg
        isPreviewReady = true
        pathCount = result.pathCount
        rawPointCount = result.inputPointCount
        pointCount = result.outputPointCount
        nodeCount = result.outputNodeCount
        colorCount = result.inputColorCount
        outputColorCount = result.outputColorCount
        colorPalette = result.automaticColors
        sanitizeManualColorGroups()
        if let conversionStart {
            lastConversionTime = Date().timeIntervalSince(conversionStart)
        }
        isPostProcessPending = false
        isConverting = false
        errorMessage = preservingError
    }
}
