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

struct SVGPreviewView: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "pathClick")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        let pageURL = model.workDirectory.appendingPathComponent("preview.html")
        try? Self.pageHTML.write(to: pageURL, atomically: true, encoding: .utf8)
        webView.loadFileURL(pageURL, allowingReadAccessTo: model.workDirectory)
        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pathClick")
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
            coordinator.run(webView, "setTool('\(model.previewTool == .zoom ? "zoom" : "cursor")')")
        }
        if coordinator.sentSelection != model.selectedPathIndex {
            coordinator.sentSelection = model.selectedPathIndex
            coordinator.run(webView, "setSelected(\(model.selectedPathIndex ?? -1))")
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
            guard message.name == "pathClick", let index = message.body as? Int else { return }
            let model = model
            Task { @MainActor in
                let newValue = index >= 0 ? index : nil
                model.selectedPathIndex = newValue
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
        body.tool-zoom #overlay, body.tool-hand #overlay {
            pointer-events: none;
        }
        body.tool-zoom #stage { cursor: zoom-in; }
        body.tool-zoom.alt #stage { cursor: zoom-out; }
        body.tool-hand #stage { cursor: grab; }
        body.tool-hand.panning #stage { cursor: grabbing; }
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
    </style>
    </head>
    <body>
    <div id="stage"><div id="wrap"><img id="raster"><div id="overlay"></div></div></div>
    <script>
        const wrap = document.getElementById('wrap');
        const raster = document.getElementById('raster');
        const overlay = document.getElementById('overlay');

        function setImage(src) {
            overlay.innerHTML = '';
            raster.style.opacity = 1;
            raster.src = src;
            wrap.style.display = 'inline-block';
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
        let tool = 'cursor';        // 'cursor' | 'zoom'
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
            if (!spaceDown) return;
            panning = true;
            document.body.classList.add('panning');
            panStartX = e.clientX; panStartY = e.clientY;
            panTx = tx; panTy = ty;
            e.preventDefault();
        });
        document.addEventListener('mousemove', e => {
            if (!panning) return;
            tx = panTx + e.clientX - panStartX;
            ty = panTy + e.clientY - panStartY;
            wrap.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')';
        });
        document.addEventListener('mouseup', () => {
            if (!panning) return;
            panning = false;
            document.body.classList.remove('panning');
            rebuildPoints();
        });

        // ---- Shape selection ----
        let selectedIdx = -1;

        function shapePaths() {
            const s = overlay.querySelector('svg');
            return s ? Array.from(s.querySelectorAll(':scope > path')) : [];
        }

        function setSelected(idx) {
            selectedIdx = idx;
            rebuildPoints();
        }

        document.addEventListener('click', e => {
            if (spaceDown) return;
            if (tool === 'zoom') {
                zoomAt(e.clientX, e.clientY, (altDown || e.altKey) ? 1 / 1.5 : 1.5);
                return;
            }
            const paths = shapePaths();
            const idx = paths.indexOf(e.target);
            selectedIdx = idx;
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
            if (spaceDown || selectedIdx < 0 || selectedIdx >= paths.length) return;
            const out = { anchors: [], controls: [], handles: [] };
            const p = paths[selectedIdx];
            const tr = parseTranslate(p.getAttribute('transform'));
            parseD(p.getAttribute('d') || '', tr[0], tr[1], out);
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
