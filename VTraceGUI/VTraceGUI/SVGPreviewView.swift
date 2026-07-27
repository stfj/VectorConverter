//
//  SVGPreviewView.swift
//  VTraceGUI
//
//  WKWebView-based preview: the source raster sits under the traced SVG,
//  and hovering a vector path highlights it in yellow (same behavior as
//  the vtracer website).
//

import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// WKWebView registers itself for drags, so image drops over the preview never
/// reach SwiftUI's onDrop. Intercept them here and hand them to the app instead.
final class ImageDropWebView: WKWebView {
    var onImageDrop: ((NSPasteboard) -> Bool)?
    var onKeyboardFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onKeyboardFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onKeyboardFocusChange?(false) }
        return resigned
    }

    private func pasteboardHasImage(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if pasteboard.canReadObject(forClasses: [NSURL.self],
                                    options: AppModel.imageURLReadingOptions) {
            return true
        }
        return pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pasteboardHasImage(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        pasteboardHasImage(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        pasteboardHasImage(sender) ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if pasteboardHasImage(sender), let onImageDrop {
            return onImageDrop(sender.draggingPasteboard)
        }
        return super.performDragOperation(sender)
    }
}

struct SVGPreviewView: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "pathClick")
        configuration.userContentController.add(context.coordinator, name: "lassoSelect")
        configuration.userContentController.add(context.coordinator, name: "anchorSelect")
        configuration.userContentController.add(context.coordinator, name: "brushStroke")
        let webView = ImageDropWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        let model = model
        webView.onImageDrop = { pasteboard in
            model.loadImage(fromPasteboard: pasteboard, fallbackName: "dropped-image")
        }
        webView.onKeyboardFocusChange = { focused in
            model.setPreviewKeyboardFocus(focused)
        }
        let pageURL = model.workDirectory.appendingPathComponent("preview.html")
        try? Self.pageHTML.write(to: pageURL, atomically: true, encoding: .utf8)
        webView.loadFileURL(pageURL, allowingReadAccessTo: model.workDirectory)
        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pathClick")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "lassoSelect")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "anchorSelect")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "brushStroke")
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.sentImageVersion != model.imageVersion {
            coordinator.sentImageVersion = model.imageVersion
            coordinator.sentSVG = nil
            coordinator.sentPreviewRevision = model.previewRevision
            coordinator.run(
                webView,
                "setImage('input.png?v=\(model.imageVersion)', \(model.previewRevision))"
            )
        }
        if let svg = model.svgText, coordinator.sentSVG != svg {
            coordinator.sentSVG = svg
            // setSVG replaces the DOM, so any immediate deletion mask must be
            // resent even though the model's deleted-index set did not change.
            coordinator.sentDeleted = []
            if let data = try? JSONEncoder().encode(svg), let json = String(data: data, encoding: .utf8) {
                coordinator.sentPreviewRevision = model.previewRevision
                coordinator.run(webView, "setSVG(\(json), \(model.previewRevision))")
            }
        }
        if coordinator.sentPreviewRevision != model.previewRevision {
            coordinator.sentPreviewRevision = model.previewRevision
            coordinator.run(webView, "setPreviewRevision(\(model.previewRevision))")
        }
        if coordinator.sentConverting != model.isConverting {
            coordinator.sentConverting = model.isConverting
            coordinator.run(webView, "setConverting(\(model.isConverting))")
        }
        if coordinator.sentSpaceDown != model.spaceDown {
            coordinator.sentSpaceDown = model.spaceDown
            coordinator.run(webView, "setSpaceDown(\(model.spaceDown))")
        }
        if coordinator.sentAltDown != model.altDown {
            coordinator.sentAltDown = model.altDown
            coordinator.run(webView, "setAltDown(\(model.altDown))")
        }
        if coordinator.sentTool != model.previewTool {
            coordinator.sentTool = model.previewTool
            let name: String
            switch model.previewTool {
            case .cursor: name = "cursor"
            case .zoom: name = "zoom"
            case .wand: name = "wand"
            case .anchor: name = "anchor"
            case .hand: name = "hand"
            case .addBrush: name = "brush-add"
            case .subtractBrush: name = "brush-subtract"
            }
            coordinator.run(webView, "setTool('\(name)')")
        }
        if coordinator.sentBrushSize != model.brushSize {
            coordinator.sentBrushSize = model.brushSize
            coordinator.run(webView, "setBrushSize(\(model.brushSize))")
        }
        if coordinator.sentBrushEnabled != model.brushInteractionEnabled {
            coordinator.sentBrushEnabled = model.brushInteractionEnabled
            coordinator.run(
                webView,
                "setBrushEnabled(\(model.brushInteractionEnabled))"
            )
        }
        if coordinator.sentBrushFeedbackVersion != model.brushFeedbackVersion {
            coordinator.sentBrushFeedbackVersion = model.brushFeedbackVersion
            coordinator.run(webView, "clearBrushFeedback()")
        }
        if coordinator.sentHighlightedColorHex != model.highlightedColorHex {
            coordinator.sentHighlightedColorHex = model.highlightedColorHex
            if let hex = model.highlightedColorHex,
               let data = try? JSONEncoder().encode(hex),
               let json = String(data: data, encoding: .utf8) {
                coordinator.run(webView, "setHighlightedColor(\(json))")
            } else {
                coordinator.run(webView, "setHighlightedColor(null)")
            }
        }
        if coordinator.sentSelection != model.selectedPathIndex {
            coordinator.sentSelection = model.selectedPathIndex
            coordinator.run(webView, "setSelected(\(model.selectedPathIndex ?? -1))")
        }
        if coordinator.sentLasso != model.lassoSelection {
            coordinator.sentLasso = model.lassoSelection
            let list = model.lassoSelection.sorted().map(String.init).joined(separator: ",")
            coordinator.run(webView, "setLassoSelection([\(list)])")
        }
        if coordinator.sentDeleted != model.deletedPaths {
            coordinator.sentDeleted = model.deletedPaths
            // Hide deleted shapes immediately; the re-simplified SVG (which
            // can take a while on big traces) replaces them properly later.
            let list = model.deletedPaths.sorted().map(String.init).joined(separator: ",")
            coordinator.run(webView, "setDeletedPaths([\(list)])")
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let model: AppModel
        var sentImageVersion = 0
        var sentSVG: String?
        var sentConverting = false
        var sentSpaceDown = false
        var sentAltDown = false
        var sentTool = PreviewTool.cursor
        var sentBrushSize = 0.0
        var sentBrushEnabled = true
        var sentBrushFeedbackVersion = 0
        var sentHighlightedColorHex: String?
        var sentPreviewRevision = 0
        var sentSelection: Int?
        var sentLasso: Set<Int> = []
        var sentDeleted: Set<Int> = []
        private var pageLoaded = false
        private var pendingScripts: [String] = []

        init(model: AppModel) {
            self.model = model
        }

        func run(_ webView: WKWebView, _ script: String) {
            if pageLoaded {
                webView.evaluateJavaScript(script)
            } else {
                pendingScripts.append(script)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            pendingScripts.forEach { webView.evaluateJavaScript($0) }
            pendingScripts.removeAll()
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            let model = model
            if message.name == "pathClick",
               let payload = message.body as? [String: Any],
               let index = number(payload["index"]).map(Int.init),
               let revision = number(payload["previewRevision"]).map(Int.init) {
                // The page already cleared its lasso; mirror that so the
                // model sync doesn't echo a stale state back.
                sentLasso = []
                Task { @MainActor in
                    guard revision == model.previewRevision,
                          model.editingInteractionEnabled else { return }
                    model.selectPath(index >= 0 ? index : nil)
                }
            } else if message.name == "lassoSelect",
                      let payload = message.body as? [String: Any],
                      let values = payload["indices"] as? [Any],
                      let revision = number(payload["previewRevision"]).map(Int.init) {
                // Pre-set the sent state so updateNSView doesn't echo this
                // selection straight back and clobber the page's lasso.
                let indices = values.compactMap { number($0).map(Int.init) }
                let set = Set(indices)
                sentLasso = set
                sentSelection = nil
                Task { @MainActor in
                    guard revision == model.previewRevision,
                          model.editingInteractionEnabled else { return }
                    model.setLassoSelection(set)
                }
            } else if message.name == "anchorSelect",
                      let payload = message.body as? [String: Any],
                      let values = payload["indices"] as? [Any],
                      let revision = number(payload["previewRevision"]).map(Int.init) {
                let indices = values.compactMap { number($0).map(Int.init) }
                Task { @MainActor in
                    guard revision == model.previewRevision,
                          model.editingInteractionEnabled else { return }
                    model.setSelectedAnchors(Set(indices))
                }
            } else if message.name == "brushStroke",
                      let payload = message.body as? [String: Any],
                      let pathIndex = number(payload["pathIndex"]).map(Int.init),
                      let diameter = number(payload["diameter"]),
                      let operationName = payload["operation"] as? String,
                      let operation = ShapeBrushOperation(rawValue: operationName),
                      let previewRevision = number(payload["previewRevision"]).map(Int.init),
                      let points = points(payload["points"]),
                      let transform = transform(payload["localToRoot"]) {
                Task { @MainActor in
                    model.applyBrushStroke(to: pathIndex,
                                           points: points,
                                           diameter: diameter,
                                           pathTransform: transform,
                                           operation: operation,
                                           previewRevision: previewRevision)
                }
            }
        }

        private func number(_ value: Any?) -> Double? {
            if let number = value as? NSNumber { return number.doubleValue }
            return value as? Double
        }

        private func points(_ value: Any?) -> [CGPoint]? {
            guard let rows = value as? [Any] else { return nil }
            let parsed = rows.compactMap { row -> CGPoint? in
                guard let pair = row as? [Any], pair.count >= 2,
                      let x = number(pair[0]), let y = number(pair[1]) else { return nil }
                return CGPoint(x: x, y: y)
            }
            return parsed.isEmpty ? nil : parsed
        }

        private func transform(_ value: Any?) -> CGAffineTransform? {
            guard let values = value as? [Any], values.count == 6 else { return nil }
            let numbers = values.compactMap(number)
            guard numbers.count == 6 else { return nil }
            return CGAffineTransform(a: numbers[0], b: numbers[1],
                                     c: numbers[2], d: numbers[3],
                                     tx: numbers[4], ty: numbers[5])
        }
    }

    private static let pageHTML = """
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>
        html, body {
            margin: 0;
            width: 100%;
            height: 100%;
            overflow: hidden;
            background: #1d1d1f;
        }
        #stage {
            width: 100%;
            height: 100%;
            display: flex;
            align-items: center;
            justify-content: center;
            box-sizing: border-box;
            padding: 20px;
        }
        #wrap {
            position: relative;
            display: none;
            line-height: 0;
            transform-origin: 0 0;
            background-image: conic-gradient(#e4e4e4 25%, #ffffff 0 50%, #e4e4e4 0 75%, #ffffff 0);
            background-size: 20px 20px;
            box-shadow: 0 6px 28px rgba(0, 0, 0, 0.55);
        }
        #raster {
            max-width: calc(100vw - 40px);
            max-height: calc(100vh - 40px);
            width: auto;
            height: auto;
            opacity: 1;
            transition: opacity 0.15s;
            -webkit-user-drag: none;
            user-select: none;
        }
        body.tool-zoom #overlay,
        body.tool-hand #overlay,
        body.tool-wand #overlay,
        body.tool-brush-add #overlay,
        body.tool-brush-subtract #overlay {
            pointer-events: none;
        }
        body.tool-zoom #stage { cursor: zoom-in; }
        body.tool-zoom.alt #stage { cursor: zoom-out; }
        body.tool-hand #stage { cursor: grab; }
        body.tool-hand.panning #stage { cursor: grabbing; }
        body.tool-wand #stage { cursor: crosshair; }
        body.tool-brush-add #stage,
        body.tool-brush-subtract #stage { cursor: crosshair; }
        body.has-svg.tool-brush-add #wrap,
        body.has-svg.tool-brush-subtract #wrap { cursor: none; }
        body.brush-disabled.tool-brush-add #stage,
        body.brush-disabled.tool-brush-subtract #stage,
        body.brush-disabled.tool-brush-add #wrap,
        body.brush-disabled.tool-brush-subtract #wrap { cursor: progress; }
        /* Point tool: shapes aren't click targets — only the anchor dots are. */
        body.tool-anchor #overlay svg > path { pointer-events: none; }
        body.tool-anchor #stage { cursor: crosshair; }
        #lasso {
            position: fixed;
            inset: 0;
            width: 100%;
            height: 100%;
            pointer-events: none;
        }
        #lasso path {
            fill: rgba(10, 132, 255, 0.08);
            stroke: #0a84ff;
            stroke-width: 1.5;
            stroke-dasharray: 6 4;
            animation: ants 0.4s linear infinite;
        }
        @keyframes ants {
            to { stroke-dashoffset: -10; }
        }
        #overlay {
            position: absolute;
            inset: 0;
        }
        #overlay svg {
            width: 100%;
            height: 100%;
            display: block;
        }
        #overlay svg > path {
            cursor: pointer;
        }
        #overlay svg > path:hover {
            stroke: #ff0;
            stroke-width: 1.5;
            vector-effect: non-scaling-stroke;
        }
        #overlay svg.color-highlight-active > path:not(.color-highlight) {
            opacity: 0.16;
        }
        #overlay svg.color-highlight-active > path.color-highlight {
            opacity: 1 !important;
            stroke: #00e5ff !important;
            stroke-width: 2.5 !important;
            stroke-linejoin: round;
            vector-effect: non-scaling-stroke;
        }
        #overlay svg > path.wandsel {
            stroke: #ff0;
            stroke-width: 1.5;
            vector-effect: non-scaling-stroke;
            fill: #ff0;
            fill-opacity: 0.5;
        }
        #overlay svg > path.brush-target {
            stroke: #0a84ff;
            stroke-width: 1.5;
            vector-effect: non-scaling-stroke;
        }
        #brushui {
            pointer-events: none;
        }
        #brushcursor {
            fill: rgba(255, 255, 255, 0.07);
            stroke: rgba(255, 255, 255, 0.95);
            stroke-width: 1;
            vector-effect: non-scaling-stroke;
        }
        #brushcursor.add {
            stroke: #30d158;
        }
        #brushcursor.subtract {
            stroke: #ff453a;
        }
        #brushgesture {
            fill: none;
            stroke-linecap: round;
            stroke-linejoin: round;
            opacity: 0.4;
        }
        #brushgesture.add {
            stroke: #30d158;
        }
        #brushgesture.subtract {
            stroke: #ff453a;
        }
        #wandhud {
            position: fixed;
            top: 14px;
            left: 50%;
            transform: translateX(-50%);
            background: rgba(20, 20, 22, 0.85);
            color: #fff;
            font: 12px -apple-system, sans-serif;
            padding: 8px 14px;
            border-radius: 8px;
            opacity: 0;
            transition: opacity 0.15s;
            pointer-events: none;
            text-align: center;
        }
        #wandhudtrack {
            margin-top: 6px;
            width: 200px;
            height: 4px;
            border-radius: 2px;
            background: rgba(255, 255, 255, 0.25);
        }
        #wandhudfill {
            height: 100%;
            border-radius: 2px;
            background: #0a84ff;
        }
    </style>
    </head>
    <body>
    <div id="stage"><div id="wrap"><img id="raster"><div id="overlay"></div></div></div>
    <svg id="lasso" xmlns="http://www.w3.org/2000/svg"></svg>
    <div id="wandhud"><div id="wandhudlabel"></div><div id="wandhudtrack"><div id="wandhudfill"></div></div></div>
    <script>
        const wrap = document.getElementById('wrap');
        const raster = document.getElementById('raster');
        const overlay = document.getElementById('overlay');
        const SVGNS = 'http://www.w3.org/2000/svg';
        let highlightedColor = null;

        function setImage(src, revision) {
            clearBrushFeedback();
            setPreviewRevision(revision);
            document.body.classList.remove('has-svg');
            overlay.innerHTML = '';
            resetBrushUI();
            raster.style.opacity = 1;
            raster.src = src;
            wrap.style.display = 'inline-block';
            clearLasso();
            selectedIndices = [];
            resetView();
        }

        function setSVG(text, revision) {
            setPreviewRevision(revision);
            // A prior stroke can finish processing while the user is already
            // drawing the next one. Keep that live gesture across the DOM swap;
            // its root-SVG coordinates remain valid against the new geometry.
            const redrawLiveBrush = brushActive && brushPoints.length > 0;
            overlay.innerHTML = text;
            resetBrushUI();
            const s = overlay.querySelector('svg');
            document.body.classList.toggle('has-svg', !!s);
            if (s) {
                if (!s.getAttribute('viewBox')) {
                    const w = s.getAttribute('width'), h = s.getAttribute('height');
                    if (w && h) s.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
                }
                s.removeAttribute('width');
                s.removeAttribute('height');
                raster.style.opacity = 0;
            }
            // The path geometry just changed; any anchor selection is stale.
            selectedAnchorSet.clear();
            anchorNearest = null;
            rebuildPoints();
            if (redrawLiveBrush) drawBrushGesture();
            updateBrushCursor(lastPointerX, lastPointerY);
            applyColorHighlight();
        }

        function normalizedHex(value) {
            if (typeof value !== 'string') return null;
            const trimmed = value.trim().toUpperCase();
            if (/^#[0-9A-F]{6}$/.test(trimmed)) return trimmed;
            if (/^#[0-9A-F]{3}$/.test(trimmed)) {
                return '#' + trimmed.slice(1).split('').map(c => c + c).join('');
            }
            return null;
        }

        function applyColorHighlight() {
            const s = overlay.querySelector('svg');
            if (!s) return;
            const wanted = normalizedHex(highlightedColor);
            let matchCount = 0;
            shapePaths().forEach(path => {
                const isVisible = path.style.display !== 'none' &&
                    !!(path.getAttribute('d') || '').trim();
                const matches = isVisible && wanted !== null &&
                    normalizedHex(path.getAttribute('fill')) === wanted;
                path.classList.toggle('color-highlight', matches);
                if (matches) matchCount += 1;
            });
            s.classList.toggle('color-highlight-active', matchCount > 0);
        }

        function setHighlightedColor(hex) {
            highlightedColor = normalizedHex(hex);
            applyColorHighlight();
        }

        function setConverting(on) {
            // Keep the last SVG visible while re-converting; only dim the raster
            // when there is no vector output to show yet.
            if (on && !overlay.firstChild) {
                raster.style.opacity = 0.5;
            }
        }

        // ---- Tools, zoom, pan & shape brushes ----
        let tool = 'cursor';
        let spaceDown = false;      // temporary hand tool while held
        let altDown = false;
        let brushEnabled = true;
        let brushSubmissionPending = false;
        let brushSize = 32;         // root SVG/source pixels
        let scale = 1, tx = 0, ty = 0;

        let brushActive = false;
        let activeBrushOperation = 'add';
        let brushPoints = [];
        let brushLastClient = null;
        let brushUI = null, brushCursor = null, brushGesture = null;
        let lastPointerX = null, lastPointerY = null;
        let brushGestureSequence = 0;
        let activeBrushGestureSequence = 0;
        let previewRevision = 0;

        function isBrushTool() {
            return tool === 'brush-add' || tool === 'brush-subtract';
        }

        function effectiveBrushOperation() {
            if (tool === 'brush-subtract') return 'subtract';
            return altDown && tool === 'brush-add' ? 'subtract' : 'add';
        }

        function canUseBrush() {
            return brushEnabled && !brushSubmissionPending;
        }

        function isHandActive() {
            return spaceDown || tool === 'hand';
        }

        function setTool(t) {
            if (brushActive) cancelBrushStroke();
            if (t !== 'anchor') selectedAnchorSet.clear();
            tool = t;
            updateToolClasses();
            rebuildPoints();
            updateBrushCursor(lastPointerX, lastPointerY);
        }

        function setBrushSize(size) {
            if (Number.isFinite(size) && size > 0) brushSize = size;
            drawBrushGesture();
            updateBrushCursor(lastPointerX, lastPointerY);
        }

        function setBrushEnabled(enabled) {
            brushEnabled = !!enabled;
            if (!brushEnabled) clearBrushFeedback();
            updateToolClasses();
            updateBrushCursor(lastPointerX, lastPointerY);
        }

        function setPreviewRevision(revision) {
            if (!Number.isFinite(revision) || revision === previewRevision) return;
            previewRevision = revision;
            selectedIndices = [];
            selectedAnchorSet.clear();
            anchorNearest = null;
            clearLasso();
            rebuildPoints();
        }

        function setSpaceDown(d) {
            if (d && brushActive) cancelBrushStroke();
            spaceDown = d;
            updateToolClasses();
            rebuildPoints();
            updateBrushCursor(lastPointerX, lastPointerY);
        }

        function setAltDown(d) {
            altDown = d;
            updateToolClasses();
            updateBrushCursor(lastPointerX, lastPointerY);
        }

        function updateToolClasses() {
            const b = document.body;
            const hand = isHandActive();
            b.classList.toggle('tool-hand', hand);
            b.classList.toggle('tool-zoom', !hand && tool === 'zoom');
            b.classList.toggle('tool-wand', !hand && tool === 'wand');
            b.classList.toggle('tool-anchor', !hand && tool === 'anchor');
            const brushOperation = effectiveBrushOperation();
            b.classList.toggle('tool-brush-add',
                !hand && isBrushTool() && brushOperation === 'add');
            b.classList.toggle('tool-brush-subtract',
                !hand && isBrushTool() && brushOperation === 'subtract');
            b.classList.toggle('brush-disabled', !canUseBrush());
            b.classList.toggle('alt', altDown);
        }

        function applyTransform() {
            wrap.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')';
            rebuildPoints();   // keep point markers a constant screen size
            updateBrushCursor(lastPointerX, lastPointerY);
        }

        function resetView() {
            scale = 1; tx = 0; ty = 0;
            applyTransform();
        }

        function zoomAt(clientX, clientY, factor) {
            const newScale = Math.min(64, Math.max(0.05, scale * factor));
            const realFactor = newScale / scale;
            const rect = wrap.getBoundingClientRect();
            const qx = clientX - (rect.left - tx);
            const qy = clientY - (rect.top - ty);
            tx = qx - (qx - tx) * realFactor;
            ty = qy - (qy - ty) * realFactor;
            scale = newScale;
            applyTransform();
        }

        function selectedBrushPath() {
            if (wandMode || selectedIndices.length !== 1) return null;
            const paths = shapePaths();
            const path = paths[selectedIndices[0]];
            if (!path || path.style.display === 'none') return null;
            return path;
        }

        function activeSVG() {
            return overlay.querySelector('svg');
        }

        function isInsideSVG(clientX, clientY) {
            const svg = activeSVG();
            if (!svg || !Number.isFinite(clientX) || !Number.isFinite(clientY)) return false;
            const rect = svg.getBoundingClientRect();
            return clientX >= rect.left && clientX <= rect.right &&
                   clientY >= rect.top && clientY <= rect.bottom;
        }

        function clientToRoot(clientX, clientY) {
            const svg = activeSVG();
            if (!svg) return null;
            try {
                const matrix = svg.getScreenCTM();
                if (!matrix) return null;
                return new DOMPoint(clientX, clientY).matrixTransform(matrix.inverse());
            } catch (err) {
                return null;
            }
        }

        function pathLocalToRoot(path) {
            const svg = activeSVG();
            if (!svg || !path) return null;
            try {
                const rootScreen = svg.getScreenCTM();
                const pathScreen = path.getScreenCTM();
                if (!rootScreen || !pathScreen) return null;
                return rootScreen.inverse().multiply(pathScreen);
            } catch (err) {
                return null;
            }
        }

        function ensureBrushUI() {
            const svg = activeSVG();
            if (!svg) return false;
            if (brushUI && brushUI.ownerSVGElement === svg) return true;

            brushUI = document.createElementNS(SVGNS, 'g');
            brushUI.setAttribute('id', 'brushui');

            brushGesture = document.createElementNS(SVGNS, 'path');
            brushGesture.setAttribute('id', 'brushgesture');
            brushGesture.style.display = 'none';
            brushUI.appendChild(brushGesture);

            brushCursor = document.createElementNS(SVGNS, 'circle');
            brushCursor.setAttribute('id', 'brushcursor');
            brushCursor.style.display = 'none';
            brushUI.appendChild(brushCursor);

            svg.appendChild(brushUI);
            return true;
        }

        function resetBrushUI() {
            brushUI = null;
            brushCursor = null;
            brushGesture = null;
        }

        function updateBrushCursor(clientX, clientY) {
            lastPointerX = clientX;
            lastPointerY = clientY;
            if (!ensureBrushUI()) return;

            const visible = canUseBrush() && isBrushTool() && !isHandActive() &&
                isInsideSVG(clientX, clientY);
            const point = visible ? clientToRoot(clientX, clientY) : null;
            if (!point) {
                brushCursor.style.display = 'none';
                return;
            }
            brushCursor.setAttribute('cx', point.x);
            brushCursor.setAttribute('cy', point.y);
            brushCursor.setAttribute('r', brushSize / 2);
            brushCursor.setAttribute('class',
                effectiveBrushOperation() === 'add' ? 'add' : 'subtract');
            brushCursor.style.display = '';
        }

        function drawBrushGesture() {
            if (!ensureBrushUI() || !brushPoints.length) return;
            let d = 'M' + brushPoints[0][0] + ' ' + brushPoints[0][1];
            if (brushPoints.length === 1) {
                d += 'l0.001 0';
            } else {
                for (let i = 1; i < brushPoints.length; i++) {
                    d += 'L' + brushPoints[i][0] + ' ' + brushPoints[i][1];
                }
            }
            brushGesture.setAttribute('d', d);
            brushGesture.setAttribute('stroke-width', brushSize);
            brushGesture.setAttribute('class',
                activeBrushOperation === 'add' ? 'add' : 'subtract');
            brushGesture.style.display = '';
        }

        function appendBrushPoint(clientX, clientY, force) {
            if (!brushActive) return;
            if (brushLastClient && !force) {
                const dx = clientX - brushLastClient[0];
                const dy = clientY - brushLastClient[1];
                if (dx * dx + dy * dy < 2.25) return;
            }
            const point = clientToRoot(clientX, clientY);
            if (!point) return;
            brushPoints.push([point.x, point.y]);
            brushLastClient = [clientX, clientY];
            // Keep exceptionally long gestures bounded while retaining their
            // complete connected silhouette.
            if (brushPoints.length > 4096) {
                brushPoints = brushPoints.filter((_, index) =>
                    index === 0 || index === brushPoints.length - 1 || index % 2 === 0);
            }
            drawBrushGesture();
        }

        function beginBrushStroke(e) {
            if (!canUseBrush() || e.button !== 0 || !selectedBrushPath() ||
                !isInsideSVG(e.clientX, e.clientY)) return false;
            brushGestureSequence += 1;
            activeBrushGestureSequence = brushGestureSequence;
            activeBrushOperation = effectiveBrushOperation();
            brushActive = true;
            brushPoints = [];
            brushLastClient = null;
            appendBrushPoint(e.clientX, e.clientY, true);
            e.preventDefault();
            return true;
        }

        function finishBrushStroke(e) {
            if (!brushActive) return false;
            appendBrushPoint(e.clientX, e.clientY, true);
            brushActive = false;

            const path = selectedBrushPath();
            const paths = shapePaths();
            const pathIndex = path ? paths.indexOf(path) : -1;
            const matrix = pathLocalToRoot(path);
            const points = brushPoints;
            const operation = activeBrushOperation;
            const gestureSequence = activeBrushGestureSequence;
            brushPoints = [];
            brushLastClient = null;

            if (pathIndex >= 0 && matrix && points.length) {
                const committedGesture = brushGesture;
                try {
                    window.webkit.messageHandlers.brushStroke.postMessage({
                        pathIndex: pathIndex,
                        operation: operation,
                        diameter: brushSize,
                        previewRevision: previewRevision,
                        points: points,
                        localToRoot: [matrix.a, matrix.b, matrix.c,
                                      matrix.d, matrix.e, matrix.f]
                    });
                    brushSubmissionPending = true;
                    updateToolClasses();
                    updateBrushCursor(e.clientX, e.clientY);
                    // The model normally replaces the SVG immediately. This is
                    // only a fallback for an invalid/no-op message.
                    setTimeout(() => {
                        if (gestureSequence === brushGestureSequence &&
                            !brushActive &&
                            committedGesture && committedGesture.isConnected) {
                            committedGesture.style.display = 'none';
                        }
                    }, 1200);
                } catch (err) {
                    if (brushGesture) brushGesture.style.display = 'none';
                }
            } else if (brushGesture) {
                brushGesture.style.display = 'none';
            }
            updateBrushCursor(e.clientX, e.clientY);
            return true;
        }

        function cancelBrushStroke() {
            brushActive = false;
            brushPoints = [];
            brushLastClient = null;
            if (brushGesture) brushGesture.style.display = 'none';
        }

        function clearBrushFeedback() {
            brushGestureSequence += 1;
            brushSubmissionPending = false;
            cancelBrushStroke();
            updateToolClasses();
            updateBrushCursor(lastPointerX, lastPointerY);
        }

        let panning = false, panStartX = 0, panStartY = 0, panTx = 0, panTy = 0;
        document.addEventListener('mousedown', e => {
            lastPointerX = e.clientX;
            lastPointerY = e.clientY;
            if (!isHandActive()) {
                if (isBrushTool()) {
                    beginBrushStroke(e);
                } else if (tool === 'wand') {
                    clearLasso();
                    lassoActive = true;
                    lassoPts = [[e.clientX, e.clientY]];
                    drawLasso(false);
                    e.preventDefault();
                } else if (tool === 'anchor') {
                    // Pressing on an anchor dot toggles it (handled on click);
                    // pressing empty space begins a box select.
                    if (e.target && e.target.tagName === 'circle') return;
                    marquee = { x0: e.clientX, y0: e.clientY, x1: e.clientX, y1: e.clientY };
                    marqueeMoved = false;
                    e.preventDefault();
                }
                return;
            }
            panning = true;
            document.body.classList.add('panning');
            panStartX = e.clientX; panStartY = e.clientY;
            panTx = tx; panTy = ty;
            e.preventDefault();
        });

        document.addEventListener('mousemove', e => {
            updateBrushCursor(e.clientX, e.clientY);
            if (brushActive) {
                appendBrushPoint(e.clientX, e.clientY, false);
                return;
            }
            if (marquee) {
                marquee.x1 = e.clientX; marquee.y1 = e.clientY;
                const dx = e.clientX - marquee.x0, dy = e.clientY - marquee.y0;
                if (marqueeMoved || dx * dx + dy * dy >= 9) {
                    marqueeMoved = true;
                    drawMarquee(marquee.x0, marquee.y0, e.clientX, e.clientY);
                }
                return;
            }
            if (lassoActive) {
                const last = lassoPts[lassoPts.length - 1];
                const dx = e.clientX - last[0], dy = e.clientY - last[1];
                if (dx * dx + dy * dy > 4) {
                    lassoPts.push([e.clientX, e.clientY]);
                    drawLasso(false);
                }
                return;
            }
            if (!panning) return;
            tx = panTx + e.clientX - panStartX;
            ty = panTy + e.clientY - panStartY;
            wrap.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')';
            updateBrushCursor(e.clientX, e.clientY);
        });

        document.addEventListener('mouseup', e => {
            if (brushActive) {
                finishBrushStroke(e);
                return;
            }
            if (marquee) {
                if (marqueeMoved) {
                    applyMarquee(marquee.x0, marquee.y0, marquee.x1, marquee.y1, e.shiftKey);
                    suppressAnchorClick = true;   // don't let the trailing click clear it
                }
                clearMarquee();
                marquee = null;
                return;
            }
            if (lassoActive) {
                finishLasso();
                return;
            }
            if (!panning) return;
            panning = false;
            document.body.classList.remove('panning');
            rebuildPoints();
            updateBrushCursor(e.clientX, e.clientY);
        });

        document.addEventListener('mouseleave', e => {
            if (brushActive && e.buttons === 0) cancelBrushStroke();
            updateBrushCursor(null, null);
        });
        window.addEventListener('blur', () => {
            cancelBrushStroke();
            if (panning) {
                panning = false;
                document.body.classList.remove('panning');
            }
        });

        // ---- Magic wand lasso (W): select shapes in an area, scroll to
        // tune the size cutoff so only the small ones stay selected ----
        const lassoSvg = document.getElementById('lasso');
        let lassoActive = false, lassoPts = [], lassoEl = null;
        let candidates = [];   // {idx, size} from the last completed lasso
        let threshold = 0;     // shapes with size <= threshold stay selected

        function drawLasso(closed) {
            if (!lassoEl) {
                lassoEl = document.createElementNS(SVGNS, 'path');
                lassoSvg.appendChild(lassoEl);
            }
            let d = 'M' + lassoPts[0][0] + ' ' + lassoPts[0][1];
            for (let i = 1; i < lassoPts.length; i++) {
                d += 'L' + lassoPts[i][0] + ' ' + lassoPts[i][1];
            }
            lassoEl.setAttribute('d', d + (closed ? 'Z' : ''));
        }

        function clearLasso() {
            lassoActive = false;
            lassoPts = [];
            candidates = [];
            if (lassoEl) { lassoEl.remove(); lassoEl = null; }
            wandHud.style.opacity = 0;
        }

        function pointInPolygon(x, y, pts) {
            let inside = false;
            for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
                const xi = pts[i][0], yi = pts[i][1], xj = pts[j][0], yj = pts[j][1];
                if ((yi > y) !== (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
                    inside = !inside;
                }
            }
            return inside;
        }

        // Rough filled area of a path, via the shoelace formula over its
        // on-curve anchor points (curve bulge ignored — fast, no layout reads).
        // Signed areas sum per subpath, so holes (opposite winding) subtract:
        // a thin outline reads as small, a solid interior as large. Translate
        // transforms don't affect area, so they're ignored.
        function shapeArea(p) {
            const d = p.getAttribute('d');
            if (!d) return 0;
            const tokens = d.match(/[A-Za-z]|[-+0-9.eE]+/g);
            if (!tokens) return 0;
            let i = 0, cmd = '', cx = 0, cy = 0, sx = 0, sy = 0, area2 = 0, open = false;
            const num = () => parseFloat(tokens[i++]);
            const closeSub = () => {
                if (open) { area2 += cx * sy - sx * cy; open = false; }
            };
            while (i < tokens.length) {
                const t = tokens[i];
                if (t.length === 1 && /[A-Za-z]/.test(t)) {
                    cmd = t; i++;
                    if (cmd === 'Z' || cmd === 'z') { closeSub(); cx = sx; cy = sy; continue; }
                } else if (cmd === 'M') cmd = 'L';
                else if (cmd === 'm') cmd = 'l';
                else if (cmd === 'Z' || cmd === 'z' || cmd === '') return 0;

                if (cmd === 'M' || cmd === 'm') {
                    closeSub();
                    let x = num(), y = num();
                    if (isNaN(x) || isNaN(y)) break;
                    if (cmd === 'm') { x += cx; y += cy; }
                    cx = x; cy = y; sx = x; sy = y; open = true;
                } else if (cmd === 'L' || cmd === 'l') {
                    let x = num(), y = num();
                    if (isNaN(x) || isNaN(y)) break;
                    if (cmd === 'l') { x += cx; y += cy; }
                    area2 += cx * y - x * cy; cx = x; cy = y;
                } else if (cmd === 'C' || cmd === 'c') {
                    let x1 = num(), y1 = num(), x2 = num(), y2 = num(), x = num(), y = num();
                    if (isNaN(x) || isNaN(y)) break;
                    if (cmd === 'c') { x += cx; y += cy; }
                    area2 += cx * y - x * cy; cx = x; cy = y;
                } else {
                    return 0;   // unsupported command
                }
            }
            closeSub();
            return Math.abs(area2) / 2;
        }

        function applyThreshold() {
            selectedIndices = candidates.filter(c => c.size <= threshold).map(c => c.idx);
            wandMode = true;
            rebuildPoints();
            try {
                window.webkit.messageHandlers.lassoSelect.postMessage({
                    indices: selectedIndices,
                    previewRevision: previewRevision
                });
            } catch (err) {}
        }

        function finishLasso() {
            lassoActive = false;
            if (lassoPts.length < 3) { clearLasso(); return; }
            drawLasso(true);
            candidates = [];
            shapePaths().forEach((p, idx) => {
                if (!p.getAttribute('d')) return;       // deleted-shape placeholder
                if (p.style.display === 'none') return; // optimistically hidden delete
                const r = p.getBoundingClientRect();
                if (!pointInPolygon(r.left + r.width / 2, r.top + r.height / 2, lassoPts)) return;
                candidates.push({ idx: idx, size: Math.max(shapeArea(p), 1e-6) });
            });
            threshold = candidates.reduce((m, c) => Math.max(m, c.size), 0);
            applyThreshold();
            showWandHud();
        }

        document.addEventListener('wheel', e => {
            if (tool !== 'wand' || isHandActive() || !candidates.length) return;
            e.preventDefault();
            const sizes = candidates.map(c => c.size);
            // Smallest shape always stays selected; that's the point of the tool.
            const lo = Math.min.apply(null, sizes), hi = Math.max.apply(null, sizes);
            threshold = Math.min(hi, Math.max(lo, threshold * Math.exp(-e.deltaY * 0.005)));
            applyThreshold();
            showWandHud();
        }, { passive: false });

        // ---- Threshold HUD: shows where the size cutoff sits while scrolling ----
        const wandHud = document.getElementById('wandhud');
        const wandHudLabel = document.getElementById('wandhudlabel');
        const wandHudFill = document.getElementById('wandhudfill');
        let wandHudTimer = null;

        function showWandHud() {
            if (!candidates.length) return;
            const sizes = candidates.map(c => c.size);
            const lo = Math.min.apply(null, sizes), hi = Math.max.apply(null, sizes);
            // Position on a log scale, since sizes span orders of magnitude.
            const pct = hi > lo
                ? (Math.log(threshold) - Math.log(lo)) / (Math.log(hi) - Math.log(lo))
                : 1;
            const side = Math.round(Math.sqrt(threshold));
            wandHudLabel.textContent = selectedIndices.length + ' / ' + candidates.length
                + ' shapes \\u2264 ' + side + ' px';
            wandHudFill.style.width = Math.round(pct * 100) + '%';
            wandHud.style.opacity = 1;
            if (wandHudTimer) clearTimeout(wandHudTimer);
            wandHudTimer = setTimeout(() => { wandHud.style.opacity = 0; }, 1200);
        }

        // ---- Shape selection ----
        let selectedIndices = [];
        let wandMode = false;   // wand selections show yellow outlines, not points
        const selectedAnchorSet = new Set();   // displayed anchor indices (point tool)
        let anchorCircles = [];                // {i, el} for the drawn anchor dots
        let anchorNearest = null;              // per-anchor nearest-neighbor dist (user units)
        // Rubber-band box select for the point tool (screen coords).
        let marquee = null, marqueeMoved = false, marqueeEl = null;
        let suppressAnchorClick = false;

        function shapePaths() {
            const s = overlay.querySelector('svg');
            return s ? Array.from(s.querySelectorAll(':scope > path')) : [];
        }

        function setSelected(idx) {
            // A deselect from the app must not clobber a live wand selection.
            if (idx < 0 && selectedIndices.length > 1) return;
            selectedIndices = idx >= 0 ? [idx] : [];
            wandMode = false;
            selectedAnchorSet.clear();   // different shape → anchors no longer apply
            anchorNearest = null;
            if (idx < 0) clearLasso();
            rebuildPoints();
        }

        function reportAnchors() {
            try {
                window.webkit.messageHandlers.anchorSelect.postMessage({
                    indices: Array.from(selectedAnchorSet),
                    previewRevision: previewRevision
                });
            } catch (err) {}
        }

        function toggleAnchor(i) {
            if (selectedAnchorSet.has(i)) selectedAnchorSet.delete(i);
            else selectedAnchorSet.add(i);
            reportAnchors();
            rebuildPoints();
        }

        // Distance from each anchor to its closest neighbor (user units), so a
        // dot's click target can grow into surrounding empty space. Cached and
        // only recomputed when the anchor set changes, not on every pan/zoom.
        function nearestNeighborDistances(anchors) {
            const n = anchors.length;
            const best = new Array(n).fill(Infinity);
            for (let i = 0; i < n; i++) {
                for (let j = i + 1; j < n; j++) {
                    const dx = anchors[i][0] - anchors[j][0];
                    const dy = anchors[i][1] - anchors[j][1];
                    const d2 = dx * dx + dy * dy;
                    if (d2 < best[i]) best[i] = d2;
                    if (d2 < best[j]) best[j] = d2;
                }
            }
            return best.map(Math.sqrt);   // Infinity (lone anchor) stays Infinity
        }

        function drawMarquee(x0, y0, x1, y1) {
            if (!marqueeEl) {
                marqueeEl = document.createElementNS(SVGNS, 'path');
                lassoSvg.appendChild(marqueeEl);
            }
            const xa = Math.min(x0, x1), ya = Math.min(y0, y1);
            const xb = Math.max(x0, x1), yb = Math.max(y0, y1);
            marqueeEl.setAttribute('d', 'M' + xa + ' ' + ya + 'H' + xb + 'V' + yb + 'H' + xa + 'Z');
        }

        function clearMarquee() {
            if (marqueeEl) { marqueeEl.remove(); marqueeEl = null; }
        }

        // Select every anchor dot whose screen position falls in the box.
        // Plain drag replaces the selection; shift-drag adds to it.
        function applyMarquee(x0, y0, x1, y1, additive) {
            const xa = Math.min(x0, x1), ya = Math.min(y0, y1);
            const xb = Math.max(x0, x1), yb = Math.max(y0, y1);
            if (!additive) selectedAnchorSet.clear();
            anchorCircles.forEach(({ i, el }) => {
                const r = el.getBoundingClientRect();
                const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
                if (cx >= xa && cx <= xb && cy >= ya && cy <= yb) selectedAnchorSet.add(i);
            });
            reportAnchors();
            rebuildPoints();
        }

        function setLassoSelection(arr) {
            selectedIndices = arr;
            wandMode = arr.length > 0;
            if (!arr.length) clearLasso();
            rebuildPoints();
        }

        /// Deleted shapes hide instantly; the re-processed SVG catches up after.
        function setDeletedPaths(arr) {
            const dead = new Set(arr);
            shapePaths().forEach((p, idx) => {
                p.style.display = dead.has(idx) ? 'none' : '';
            });
            rebuildPoints();
            applyColorHighlight();
        }

        document.addEventListener('click', e => {
            if (isHandActive()) return;
            if (isBrushTool()) return;   // don't let the trailing click deselect
            if (tool === 'zoom') {
                zoomAt(e.clientX, e.clientY, (altDown || e.altKey) ? 1 / 1.5 : 1.5);
                return;
            }
            if (tool === 'anchor') {
                // A box select just finished — keep its result, don't clear.
                if (suppressAnchorClick) { suppressAnchorClick = false; return; }
                // Anchor dots stop propagation, so this is an empty-space click:
                // clear the point selection but keep the shape selected.
                if (selectedAnchorSet.size) { selectedAnchorSet.clear(); reportAnchors(); rebuildPoints(); }
                return;
            }
            if (tool === 'wand') return;   // clicks are lasso strokes here
            const paths = shapePaths();
            const idx = paths.indexOf(e.target);
            selectedIndices = idx >= 0 ? [idx] : [];
            wandMode = false;
            clearLasso();
            rebuildPoints();
            try {
                window.webkit.messageHandlers.pathClick.postMessage({
                    index: idx,
                    previewRevision: previewRevision
                });
            } catch (err) {}
        });

        // ---- Control point overlay (selected shape only) ----
        function parseTranslate(tr) {
            if (!tr) return [0, 0];
            const i = tr.indexOf('translate(');
            if (i < 0) return [0, 0];
            const inner = tr.slice(i + 10, tr.indexOf(')', i));
            const parts = inner.split(/[ ,]+/).map(parseFloat);
            return [parts[0] || 0, parts[1] || 0];
        }

        function parseD(d, tx, ty, out) {
            const tokens = d.match(/[A-Za-z]|[-+0-9.eE]+/g);
            if (!tokens) return;
            let i = 0, cmd = '', cx = 0, cy = 0;
            const num = () => parseFloat(tokens[i++]);
            while (i < tokens.length) {
                const t = tokens[i];
                if (t.length === 1 && /[A-Za-z]/.test(t)) {
                    cmd = t;
                    i++;
                    if (cmd === 'Z' || cmd === 'z') continue;
                } else if (cmd === 'M') {
                    cmd = 'L';
                } else if (cmd === 'm') {
                    cmd = 'l';
                } else if (cmd === 'Z' || cmd === 'z' || cmd === '') {
                    return;
                }
                if (cmd === 'M' || cmd === 'm' || cmd === 'L' || cmd === 'l') {
                    let x = num(), y = num();
                    if (isNaN(x) || isNaN(y)) return;
                    if (cmd === 'm' || cmd === 'l') { x += cx; y += cy; }
                    cx = x; cy = y;
                    out.anchors.push([x + tx, y + ty]);
                } else if (cmd === 'C' || cmd === 'c') {
                    let x1 = num(), y1 = num(), x2 = num(), y2 = num(), x = num(), y = num();
                    if (isNaN(x) || isNaN(y)) return;
                    if (cmd === 'c') { x1 += cx; y1 += cy; x2 += cx; y2 += cy; x += cx; y += cy; }
                    out.handles.push([cx + tx, cy + ty, x1 + tx, y1 + ty]);
                    out.handles.push([x + tx, y + ty, x2 + tx, y2 + ty]);
                    out.controls.push([x1 + tx, y1 + ty]);
                    out.controls.push([x2 + tx, y2 + ty]);
                    cx = x; cy = y;
                    out.anchors.push([x + tx, y + ty]);
                } else {
                    return; // unsupported command
                }
            }
        }

        function mkPath(d, color, width, cap) {
            const p = document.createElementNS(SVGNS, 'path');
            p.setAttribute('d', d);
            p.setAttribute('fill', 'none');
            p.setAttribute('stroke', color);
            p.setAttribute('stroke-width', width);
            p.setAttribute('stroke-linecap', cap);
            p.setAttribute('vector-effect', 'non-scaling-stroke');
            return p;
        }

        function rebuildPoints() {
            const s = overlay.querySelector('svg');
            if (!s) return;
            const old = s.querySelector('#ctrlpts');
            if (old) old.remove();
            const paths = shapePaths();
            paths.forEach(p => {
                p.classList.remove('wandsel');
                p.classList.remove('brush-target');
            });
            if (isHandActive() || !selectedIndices.length) return;
            if (wandMode) {
                // Wand selections highlight whole shapes, not control points.
                selectedIndices.forEach(idx => {
                    const p = paths[idx];
                    if (p && p.getAttribute('d')) p.classList.add('wandsel');
                });
                return;
            }
            if (isBrushTool()) {
                const target = paths[selectedIndices[0]];
                if (target && target.style.display !== 'none') {
                    target.classList.add('brush-target');
                }
                return;
            }
            const out = { anchors: [], controls: [], handles: [] };
            selectedIndices.forEach(idx => {
                if (idx < 0 || idx >= paths.length) return;
                const p = paths[idx];
                const tr = parseTranslate(p.getAttribute('transform'));
                parseD(p.getAttribute('d') || '', tr[0], tr[1], out);
            });
            const g = document.createElementNS(SVGNS, 'g');
            g.setAttribute('id', 'ctrlpts');

            // Point tool: anchors become individually selectable dots.
            if (tool === 'anchor' && selectedIndices.length === 1) {
                g.setAttribute('pointer-events', 'auto');
                anchorCircles = [];
                if (!anchorNearest || anchorNearest.length !== out.anchors.length) {
                    anchorNearest = nearestNeighborDistances(out.anchors);
                }
                const visR = 4 / scale;        // constant on-screen dot size
                const maxHitR = 16 / scale;    // generous target for isolated dots
                out.anchors.forEach((a, i) => {
                    const sel = selectedAnchorSet.has(i);
                    // Invisible hit target grows into empty space but never past
                    // half the distance to the nearest dot, so neighbors stay
                    // individually clickable. Always at least the visible dot.
                    const hitR = Math.max(visR, Math.min(maxHitR, anchorNearest[i] / 2));
                    const hit = document.createElementNS(SVGNS, 'circle');
                    hit.setAttribute('cx', a[0]);
                    hit.setAttribute('cy', a[1]);
                    hit.setAttribute('r', hitR);
                    hit.setAttribute('fill', 'transparent');
                    hit.setAttribute('pointer-events', 'all');
                    hit.style.cursor = 'pointer';
                    hit.addEventListener('click', ev => { ev.stopPropagation(); toggleAnchor(i); });
                    // Visible dot sits on top but ignores clicks; the hit area handles them.
                    const dot = document.createElementNS(SVGNS, 'circle');
                    dot.setAttribute('cx', a[0]);
                    dot.setAttribute('cy', a[1]);
                    dot.setAttribute('r', visR);
                    dot.setAttribute('fill', sel ? '#30d158' : '#ff3b30');
                    dot.setAttribute('stroke', '#fff');
                    dot.setAttribute('stroke-width', (sel ? 1.5 : 1) / scale);
                    dot.setAttribute('pointer-events', 'none');
                    g.appendChild(hit);
                    g.appendChild(dot);
                    anchorCircles.push({ i, el: dot });
                });
                s.appendChild(g);
                return;
            }
            anchorCircles = [];

            g.setAttribute('pointer-events', 'none');
            let handleD = '', anchorD = '', ctrlD = '';
            out.handles.forEach(h => { handleD += 'M' + h[0] + ' ' + h[1] + 'L' + h[2] + ' ' + h[3]; });
            out.anchors.forEach(a => { anchorD += 'M' + a[0] + ' ' + a[1] + 'l0.01 0'; });
            out.controls.forEach(c => { ctrlD += 'M' + c[0] + ' ' + c[1] + 'l0.01 0'; });
            // Divide widths by the CSS zoom so markers stay a constant screen size.
            if (handleD) g.appendChild(mkPath(handleD, 'rgba(10,132,255,0.45)', 0.5 / scale, 'butt'));
            if (ctrlD) g.appendChild(mkPath(ctrlD, '#0a84ff', 2 / scale, 'round'));
            if (anchorD) g.appendChild(mkPath(anchorD, '#ff3b30', 3 / scale, 'round'));
            s.appendChild(g);
        }
    </script>
    </body>
    </html>
    """
}
