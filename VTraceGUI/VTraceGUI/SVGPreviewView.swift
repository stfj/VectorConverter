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
        let webView = ImageDropWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        let model = model
        webView.onImageDrop = { pasteboard in
            model.loadImage(fromPasteboard: pasteboard, fallbackName: "dropped-image")
        }
        let pageURL = model.workDirectory.appendingPathComponent("preview.html")
        try? Self.pageHTML.write(to: pageURL, atomically: true, encoding: .utf8)
        webView.loadFileURL(pageURL, allowingReadAccessTo: model.workDirectory)
        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pathClick")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "lassoSelect")
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.sentImageVersion != model.imageVersion {
            coordinator.sentImageVersion = model.imageVersion
            coordinator.sentSVG = nil
            coordinator.run(webView, "setImage('input.png?v=\(model.imageVersion)')")
        }
        if let svg = model.svgText, coordinator.sentSVG != svg {
            coordinator.sentSVG = svg
            if let data = try? JSONEncoder().encode(svg), let json = String(data: data, encoding: .utf8) {
                coordinator.run(webView, "setSVG(\(json))")
            }
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
            }
            coordinator.run(webView, "setTool('\(name)')")
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
            if message.name == "pathClick", let index = message.body as? Int {
                // The page already cleared its lasso; mirror that so the
                // model sync doesn't echo a stale state back.
                sentLasso = []
                Task { @MainActor in
                    model.selectPath(index >= 0 ? index : nil)
                }
            } else if message.name == "lassoSelect", let indices = message.body as? [Int] {
                // Pre-set the sent state so updateNSView doesn't echo this
                // selection straight back and clobber the page's lasso.
                let set = Set(indices)
                sentLasso = set
                sentSelection = nil
                Task { @MainActor in
                    model.setLassoSelection(set)
                }
            }
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
        body.tool-zoom #overlay, body.tool-hand #overlay, body.tool-wand #overlay {
            pointer-events: none;
        }
        body.tool-zoom #stage { cursor: zoom-in; }
        body.tool-zoom.alt #stage { cursor: zoom-out; }
        body.tool-hand #stage { cursor: grab; }
        body.tool-hand.panning #stage { cursor: grabbing; }
        body.tool-wand #stage { cursor: crosshair; }
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
        #overlay svg > path.wandsel {
            stroke: #ff0;
            stroke-width: 1.5;
            vector-effect: non-scaling-stroke;
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

        function setImage(src) {
            overlay.innerHTML = '';
            raster.style.opacity = 1;
            raster.src = src;
            wrap.style.display = 'inline-block';
            clearLasso();
            selectedIndices = [];
            resetView();
        }

        function setSVG(text) {
            overlay.innerHTML = text;
            const s = overlay.querySelector('svg');
            if (s) {
                if (!s.getAttribute('viewBox')) {
                    const w = s.getAttribute('width'), h = s.getAttribute('height');
                    if (w && h) s.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
                }
                s.removeAttribute('width');
                s.removeAttribute('height');
                raster.style.opacity = 0;
            }
            rebuildPoints();
        }

        function setConverting(on) {
            // Keep the last SVG visible while re-converting; only dim the raster
            // when there is no vector output to show yet.
            if (on && !overlay.firstChild) {
                raster.style.opacity = 0.5;
            }
        }

        // ---- Tools, zoom & pan ----
        let tool = 'cursor';        // 'cursor' | 'zoom' | 'wand'
        let spaceDown = false;      // hand tool while held; also hides points
        let altDown = false;
        let scale = 1, tx = 0, ty = 0;

        function setTool(t) { tool = t; updateToolClasses(); }
        function setSpaceDown(d) { spaceDown = d; updateToolClasses(); rebuildPoints(); }
        function setAltDown(d) { altDown = d; updateToolClasses(); }

        function updateToolClasses() {
            const b = document.body;
            b.classList.toggle('tool-hand', spaceDown);
            b.classList.toggle('tool-zoom', !spaceDown && tool === 'zoom');
            b.classList.toggle('tool-wand', !spaceDown && tool === 'wand');
            b.classList.toggle('alt', altDown);
        }

        function applyTransform() {
            wrap.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')';
            rebuildPoints();   // keep point markers a constant screen size
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

        let panning = false, panStartX = 0, panStartY = 0, panTx = 0, panTy = 0;
        document.addEventListener('mousedown', e => {
            if (!spaceDown) {
                if (tool === 'wand') {
                    clearLasso();
                    lassoActive = true;
                    lassoPts = [[e.clientX, e.clientY]];
                    drawLasso(false);
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
        });
        document.addEventListener('mouseup', () => {
            if (lassoActive) {
                finishLasso();
                return;
            }
            if (!panning) return;
            panning = false;
            document.body.classList.remove('panning');
            rebuildPoints();
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

        function applyThreshold() {
            selectedIndices = candidates.filter(c => c.size <= threshold).map(c => c.idx);
            wandMode = true;
            rebuildPoints();
            try {
                window.webkit.messageHandlers.lassoSelect.postMessage(selectedIndices);
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
                const b = p.getBBox();   // SVG units: zoom-independent size
                candidates.push({ idx: idx, size: Math.max(b.width * b.height, 1e-6) });
            });
            threshold = candidates.reduce((m, c) => Math.max(m, c.size), 0);
            applyThreshold();
            showWandHud();
        }

        document.addEventListener('wheel', e => {
            if (tool !== 'wand' || !candidates.length) return;
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

        function shapePaths() {
            const s = overlay.querySelector('svg');
            return s ? Array.from(s.querySelectorAll(':scope > path')) : [];
        }

        function setSelected(idx) {
            // A deselect from the app must not clobber a live wand selection.
            if (idx < 0 && selectedIndices.length > 1) return;
            selectedIndices = idx >= 0 ? [idx] : [];
            wandMode = false;
            if (idx < 0) clearLasso();
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
        }

        document.addEventListener('click', e => {
            if (spaceDown) return;
            if (tool === 'zoom') {
                zoomAt(e.clientX, e.clientY, (altDown || e.altKey) ? 1 / 1.5 : 1.5);
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
                window.webkit.messageHandlers.pathClick.postMessage(idx);
            } catch (err) {}
        });

        // ---- Control point overlay (selected shape only) ----
        const SVGNS = 'http://www.w3.org/2000/svg';

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
            paths.forEach(p => p.classList.remove('wandsel'));
            if (spaceDown || !selectedIndices.length) return;
            if (wandMode) {
                // Wand selections highlight whole shapes, not control points.
                selectedIndices.forEach(idx => {
                    const p = paths[idx];
                    if (p && p.getAttribute('d')) p.classList.add('wandsel');
                });
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
