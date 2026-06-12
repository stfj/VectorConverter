//
//  SVGSimplifier.swift
//  VTraceGUI
//
//  Post-processing pass over vtracer's raw SVG output: re-fits each path
//  with fewer cubic béziers using Schneider's curve-fitting algorithm
//  (Graphics Gems, the same approach paper.js/Inkscape use), splitting at
//  corners so sharp features survive.
//

import Foundation
import CoreGraphics

nonisolated struct SimplificationSettings: Equatable, Sendable {
    /// Max fitting error in px. 0 disables error-driven simplification.
    var tolerance: Double = 0
    /// Vertices whose direction changes by at least this many degrees are
    /// treated as corners and preserved exactly.
    var cornerAngle: Double = 60
    /// Arc-length smoothing radius in px, applied to the outline before
    /// fitting (corners stay pinned). Erases detail below this scale.
    var smoothing: Double = 0
    /// Hard cap on anchor points per subpath; below 3 means no cap. When the
    /// budget binds, fitting error is ignored and the weakest corners are
    /// dropped so the shape fits the budget.
    var maxNodes: Double = 0

    var isActive: Bool { tolerance > 0 || smoothing > 0 || nodeBudget != nil }
    var nodeBudget: Int? { maxNodes >= 3 ? Int(maxNodes) : nil }
    /// Error used by the fitter when only smoothing/budget are active.
    var baseTolerance: Double { tolerance > 0 ? tolerance : 0.75 }
}

nonisolated enum SVGSimplifier {

    struct Result: Sendable {
        var svg: String
        var pathCount: Int
        var inputPointCount: Int
        var outputPointCount: Int
        var outputNodeCount: Int
    }

    /// `overrides` maps a path's index (document order) to settings that
    /// replace the global ones for that shape only. Paths in `deleted` are
    /// emptied (`d=""`) rather than removed, so indices stay stable for
    /// selection; exports strip the placeholders.
    static func process(_ svg: String, settings: SimplificationSettings,
                        overrides: [Int: SimplificationSettings] = [:],
                        deleted: Set<Int> = []) -> Result {
        let ns = svg as NSString
        let regex = try! NSRegularExpression(pattern: "d=\"([^\"]*)\"")
        let matches = regex.matches(in: svg, range: NSRange(location: 0, length: ns.length))

        var output = ""
        output.reserveCapacity(svg.count)
        var cursor = 0
        var pathIndex = 0
        var inputPoints = 0
        var outputPoints = 0
        var outputNodes = 0

        for match in matches {
            let effective = overrides[pathIndex] ?? settings
            let isDeleted = deleted.contains(pathIndex)
            pathIndex += 1
            let full = match.range
            output += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            cursor = full.location + full.length

            if isDeleted {
                output += "d=\"\""
                continue
            }

            let d = ns.substring(with: match.range(at: 1))
            guard let subpaths = parsePathData(d) else {
                // Unsupported path commands: pass through untouched.
                output += ns.substring(with: full)
                continue
            }
            let inCount = pointCount(of: subpaths)
            inputPoints += inCount

            if effective.isActive {
                let simplified = subpaths.map { simplifySubpath($0, settings: effective) }
                outputPoints += pointCount(of: simplified)
                outputNodes += nodeCount(of: simplified)
                output += "d=\"\(emit(simplified))\""
            } else {
                outputPoints += inCount
                outputNodes += nodeCount(of: subpaths)
                output += ns.substring(with: full)
            }
        }
        output += ns.substring(from: cursor)
        return Result(svg: output, pathCount: pathIndex,
                      inputPointCount: inputPoints, outputPointCount: outputPoints,
                      outputNodeCount: outputNodes)
    }

    // MARK: - Path model

    enum Segment {
        case line(CGPoint)
        case cubic(CGPoint, CGPoint, CGPoint)
    }

    struct SubPath {
        var start: CGPoint
        var segments: [Segment]
        var closed: Bool
    }

    private static func pointCount(of subpaths: [SubPath]) -> Int {
        subpaths.reduce(0) { total, sp in
            total + 1 + sp.segments.reduce(0) { acc, seg in
                switch seg {
                case .line: return acc + 1
                case .cubic: return acc + 3
                }
            }
        }
    }

    /// Anchor points only (what a vector editor calls nodes).
    private static func nodeCount(of subpaths: [SubPath]) -> Int {
        subpaths.reduce(0) { $0 + 1 + $1.segments.count }
    }

    // MARK: - Parsing (vtracer emits absolute M/L/C/Z; relative supported for safety)

    static func parsePathData(_ d: String) -> [SubPath]? {
        var scanner = PathScanner(d)
        var subpaths: [SubPath] = []
        var segments: [Segment] = []
        var start = CGPoint.zero
        var current = CGPoint.zero
        var open = false
        var cmd: Character = " "

        func endSubpath(closed: Bool) {
            if open {
                subpaths.append(SubPath(start: start, segments: segments, closed: closed))
            }
            segments = []
            open = false
        }

        while true {
            if let c = scanner.nextCommand() {
                cmd = c
            } else if scanner.hasNumber() {
                // Implicit command repetition; after M/m it becomes L/l.
                if cmd == "M" { cmd = "L" } else if cmd == "m" { cmd = "l" }
                if cmd == "Z" || cmd == "z" { return nil }
            } else {
                break
            }
            switch cmd {
            case "M", "m":
                guard let p = scanner.point() else { return nil }
                endSubpath(closed: false)
                start = cmd == "m" ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
                current = start
                open = true
            case "L", "l":
                guard open, let p = scanner.point() else { return nil }
                current = cmd == "l" ? CGPoint(x: current.x + p.x, y: current.y + p.y) : p
                segments.append(.line(current))
            case "C", "c":
                guard open, var c1 = scanner.point(), var c2 = scanner.point(),
                      var p = scanner.point() else { return nil }
                if cmd == "c" {
                    c1 = CGPoint(x: current.x + c1.x, y: current.y + c1.y)
                    c2 = CGPoint(x: current.x + c2.x, y: current.y + c2.y)
                    p = CGPoint(x: current.x + p.x, y: current.y + p.y)
                }
                segments.append(.cubic(c1, c2, p))
                current = p
            case "Z", "z":
                endSubpath(closed: true)
                current = start
            default:
                return nil
            }
        }
        if scanner.hadError { return nil }
        endSubpath(closed: false)
        return subpaths
    }

    private struct PathScanner {
        private let bytes: [UInt8]
        private var i = 0
        var hadError = false

        init(_ s: String) { bytes = Array(s.utf8) }

        private mutating func skipSeparators() {
            while i < bytes.count {
                let c = bytes[i]
                if c == 32 || c == 44 || c == 9 || c == 10 || c == 13 { i += 1 } else { break }
            }
        }

        mutating func nextCommand() -> Character? {
            skipSeparators()
            guard i < bytes.count else { return nil }
            let c = bytes[i]
            guard (65...90).contains(c) || (97...122).contains(c) else { return nil }
            i += 1
            return Character(UnicodeScalar(c))
        }

        mutating func hasNumber() -> Bool {
            skipSeparators()
            guard i < bytes.count else { return false }
            let c = bytes[i]
            return (48...57).contains(c) || c == 45 || c == 43 || c == 46
        }

        mutating func number() -> Double? {
            skipSeparators()
            let startIndex = i
            if i < bytes.count, bytes[i] == 45 || bytes[i] == 43 { i += 1 }
            var sawDigit = false
            while i < bytes.count, (48...57).contains(bytes[i]) { i += 1; sawDigit = true }
            if i < bytes.count, bytes[i] == 46 {
                i += 1
                while i < bytes.count, (48...57).contains(bytes[i]) { i += 1; sawDigit = true }
            }
            if sawDigit, i < bytes.count, bytes[i] == 101 || bytes[i] == 69 {
                i += 1
                if i < bytes.count, bytes[i] == 45 || bytes[i] == 43 { i += 1 }
                while i < bytes.count, (48...57).contains(bytes[i]) { i += 1 }
            }
            guard sawDigit,
                  let value = Double(String(decoding: bytes[startIndex..<i], as: UTF8.self)) else {
                hadError = true
                return nil
            }
            return value
        }

        mutating func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }
    }

    // MARK: - Simplification

    private static let resampleSpacing = 1.5

    private static func simplifySubpath(_ sp: SubPath, settings: SimplificationSettings) -> SubPath {
        var pts = flatten(sp)
        if sp.closed, pts.count > 1, distance(pts[0], pts[pts.count - 1]) < 1e-9 {
            pts.removeLast()
        }
        guard pts.count >= 3 else { return sp }

        // Uniform spacing makes the smoothing window and length-proportional
        // budget allocation behave predictably.
        if settings.smoothing > 0 || settings.nodeBudget != nil {
            pts = resample(pts, spacing: resampleSpacing, closed: sp.closed)
            guard pts.count >= 3 else { return sp }
        }

        var cornerInfo = corners(in: pts, closed: sp.closed, angleDeg: settings.cornerAngle)

        // Node budget → total bézier segment allowance; corners compete for it.
        var segmentBudget = Int.max
        if let nodes = settings.nodeBudget {
            segmentBudget = max(sp.closed ? nodes : nodes - 1, 1)
            let allowedCorners = sp.closed ? segmentBudget : max(0, segmentBudget - 1)
            if cornerInfo.count > allowedCorners {
                cornerInfo = Array(cornerInfo.sorted { $0.strength > $1.strength }
                    .prefix(allowedCorners))
                    .sorted { $0.index < $1.index }
            }
        }
        let cornerIndices = cornerInfo.map(\.index)

        let tolerance = settings.baseTolerance
        var segments: [Segment] = []
        var startPoint = pts[0]

        if sp.closed && cornerIndices.isEmpty {
            // Smooth loop: fit with a matched tangent at the seam.
            var loop = pts
            if settings.smoothing > 0 {
                loop = smoothed(loop, radius: settings.smoothing,
                                spacing: resampleSpacing, closed: true)
            }
            loop.append(loop[0])
            let seamTangent = normalize(sub(loop[1], loop[loop.count - 2]))
            var beziers: [Bez] = []
            fitCubic(loop, 0, loop.count - 1, seamTangent, scale(seamTangent, -1),
                     tolerance, segmentBudget, &beziers)
            segments = beziers.map { .cubic($0.p1, $0.p2, $0.p3) }
            startPoint = loop[0]
        } else {
            var pieces: [[CGPoint]] = []
            if sp.closed {
                // Rotate so the polyline starts at a corner, then fit corner-to-corner.
                let r = cornerIndices[0]
                let rotated = Array(pts[r...] + pts[..<r])
                let shifted = cornerIndices.map { ($0 - r + pts.count) % pts.count }.sorted()
                for k in 0..<shifted.count {
                    let a = shifted[k]
                    let b = k + 1 < shifted.count ? shifted[k + 1] : pts.count
                    var piece = Array(rotated[a...min(b, pts.count - 1)])
                    if b == pts.count { piece.append(rotated[0]) }
                    pieces.append(piece)
                }
            } else {
                var indices = [0]
                indices += cornerIndices.filter { $0 != 0 && $0 != pts.count - 1 }
                indices.append(pts.count - 1)
                for k in 0..<(indices.count - 1) {
                    pieces.append(Array(pts[indices[k]...indices[k + 1]]))
                }
            }
            if settings.smoothing > 0 {
                // Smooth piece interiors; corner endpoints stay pinned.
                pieces = pieces.map {
                    smoothed($0, radius: settings.smoothing,
                             spacing: resampleSpacing, closed: false)
                }
            }
            let allocations = allocate(segmentBudget, among: pieces)
            for (piece, allowance) in zip(pieces, allocations) {
                guard piece.count >= 2 else { continue }
                if piece.count == 2 {
                    segments.append(.line(piece[1]))
                } else {
                    for bez in fitCurve(piece, tolerance: tolerance, maxSegments: allowance) {
                        segments.append(.cubic(bez.p1, bez.p2, bez.p3))
                    }
                }
            }
            startPoint = pieces.first?.first ?? pts[0]
        }
        guard !segments.isEmpty else { return sp }
        return SubPath(start: startPoint, segments: segments, closed: sp.closed)
    }

    /// Resample a polyline at uniform arc-length spacing.
    private static func resample(_ pts: [CGPoint], spacing: Double, closed: Bool) -> [CGPoint] {
        var source = pts
        if closed { source.append(pts[0]) }
        var out = [pts[0]]
        var prev = pts[0]
        var carry = 0.0
        for p in source.dropFirst() {
            var segLen = distance(prev, p)
            while carry + segLen >= spacing && segLen > 1e-12 {
                let t = (spacing - carry) / segLen
                let np = lerp(prev, p, t)
                out.append(np)
                prev = np
                segLen = distance(prev, p)
                carry = 0
            }
            carry += segLen
            prev = p
        }
        if closed {
            if out.count > 1, distance(out[out.count - 1], out[0]) < spacing * 0.5 {
                out.removeLast()
            }
        } else if let last = pts.last, distance(out[out.count - 1], last) > 1e-9 {
            out.append(last)
        }
        return out.count >= 3 ? out : pts
    }

    /// Box-filter the polyline over an arc-length window. Open polylines keep
    /// their endpoints fixed (those are corners or path ends).
    private static func smoothed(_ pts: [CGPoint], radius: Double, spacing: Double,
                                 closed: Bool) -> [CGPoint] {
        let r = Int((radius / spacing).rounded())
        let n = pts.count
        guard r >= 1, n > 2 else { return pts }
        var out = pts
        for i in 0..<n {
            if !closed && (i == 0 || i == n - 1) { continue }
            var sx = 0.0, sy = 0.0
            var count = 0.0
            for k in -r...r {
                var j = i + k
                if closed {
                    j = ((j % n) + n) % n
                } else {
                    j = max(0, min(n - 1, j))
                }
                sx += Double(pts[j].x)
                sy += Double(pts[j].y)
                count += 1
            }
            out[i] = CGPoint(x: sx / count, y: sy / count)
        }
        return out
    }

    /// Distribute a segment allowance among pieces proportionally to length.
    private static func allocate(_ total: Int, among pieces: [[CGPoint]]) -> [Int] {
        guard total != Int.max else {
            return Array(repeating: Int.max, count: pieces.count)
        }
        let lengths = pieces.map { piece in
            piece.count < 2 ? 0.0 : (1..<piece.count).reduce(0.0) { $0 + distance(piece[$1 - 1], piece[$1]) }
        }
        let totalLength = max(lengths.reduce(0, +), 1e-9)
        var alloc = lengths.map { max(1, Int((Double(total) * $0 / totalLength).rounded())) }
        var sum = alloc.reduce(0, +)
        while sum > total {
            guard let i = alloc.indices.max(by: { alloc[$0] < alloc[$1] }), alloc[i] > 1 else { break }
            alloc[i] -= 1
            sum -= 1
        }
        return alloc
    }

    /// Sample the subpath into a dense polyline.
    private static func flatten(_ sp: SubPath) -> [CGPoint] {
        var raw = [sp.start]
        var current = sp.start
        for seg in sp.segments {
            switch seg {
            case .line(let p):
                raw.append(p)
                current = p
            case .cubic(let c1, let c2, let p):
                let estimate = distance(current, c1) + distance(c1, c2) + distance(c2, p)
                let steps = max(4, min(24, Int(estimate / 2)))
                for k in 1...steps {
                    let t = Double(k) / Double(steps)
                    raw.append(cubicPoint(current, c1, c2, p, t))
                }
                current = p
            }
        }
        var pts: [CGPoint] = []
        for p in raw where pts.last.map({ distance($0, p) > 1e-9 }) ?? true {
            pts.append(p)
        }
        return pts
    }

    /// Vertices whose direction change is at least `angleDeg`, with the
    /// deviation angle as strength (used to rank corners under a node budget).
    private static func corners(in pts: [CGPoint], closed: Bool,
                                angleDeg: Double) -> [(index: Int, strength: Double)] {
        let threshold = angleDeg * .pi / 180
        let n = pts.count
        var result: [(index: Int, strength: Double)] = []
        let range = closed ? 0..<n : 1..<(n - 1)
        for i in range {
            let p = pts[(i - 1 + n) % n]
            let q = pts[i]
            let r = pts[(i + 1) % n]
            let v1 = sub(q, p)
            let v2 = sub(r, q)
            let l1 = hypot(v1.x, v1.y)
            let l2 = hypot(v2.x, v2.y)
            guard l1 > 1e-12, l2 > 1e-12 else { continue }
            let cosA = max(-1.0, min(1.0, Double(dot(v1, v2) / (l1 * l2))))
            let deviation = acos(cosA)
            if deviation >= threshold {
                result.append((index: i, strength: deviation))
            }
        }
        return result
    }

    // MARK: - Schneider curve fitting

    private struct Bez {
        var p0, p1, p2, p3: CGPoint
    }

    private static func fitCurve(_ pts: [CGPoint], tolerance: Double,
                                 maxSegments: Int = Int.max) -> [Bez] {
        let n = pts.count
        guard n >= 2 else { return [] }
        if n == 2 {
            let d = scale(sub(pts[1], pts[0]), 1.0 / 3.0)
            return [Bez(p0: pts[0], p1: add(pts[0], d), p2: sub(pts[1], d), p3: pts[1])]
        }
        let tan1 = normalize(sub(pts[1], pts[0]))
        let tan2 = normalize(sub(pts[n - 2], pts[n - 1]))
        var result: [Bez] = []
        fitCubic(pts, 0, n - 1, tan1, tan2, tolerance, maxSegments, &result)
        return result
    }

    private static func fitCubic(_ pts: [CGPoint], _ first: Int, _ last: Int,
                                 _ tan1: CGPoint, _ tan2: CGPoint,
                                 _ tolerance: Double, _ maxSegments: Int,
                                 _ result: inout [Bez]) {
        if last - first == 1 {
            let p0 = pts[first], p3 = pts[last]
            let d = distance(p0, p3) / 3
            result.append(Bez(p0: p0, p1: add(p0, scale(tan1, d)),
                              p2: add(p3, scale(tan2, d)), p3: p3))
            return
        }

        var u = chordLengthParameterize(pts, first, last)
        let toleranceSq = tolerance * tolerance
        var split = (first + last) / 2
        var previousError = Double.infinity
        var parametersInOrder = true
        var lastBez: Bez?

        for _ in 0...4 {
            let bez = generateBezier(pts, first, last, u, tan1, tan2)
            lastBez = bez
            let (errorSq, index) = maxError(pts, first, last, bez, u)
            if errorSq < toleranceSq && parametersInOrder {
                result.append(bez)
                return
            }
            split = index
            if errorSq >= previousError { break }
            previousError = errorSq
            parametersInOrder = reparameterize(pts, first, last, &u, bez)
        }

        // Budget exhausted: accept the best least-squares fit regardless of error.
        if maxSegments <= 1, let bez = lastBez {
            result.append(bez)
            return
        }

        let centerTangent = normalize(sub(pts[split - 1], pts[split + 1]))
        let leftBudget: Int
        let rightBudget: Int
        if maxSegments == Int.max {
            leftBudget = Int.max
            rightBudget = Int.max
        } else {
            let fraction = Double(split - first) / Double(last - first)
            leftBudget = max(1, min(maxSegments - 1, Int((Double(maxSegments) * fraction).rounded())))
            rightBudget = maxSegments - leftBudget
        }
        fitCubic(pts, first, split, tan1, centerTangent, tolerance, leftBudget, &result)
        fitCubic(pts, split, last, scale(centerTangent, -1), tan2, tolerance, rightBudget, &result)
    }

    private static func generateBezier(_ pts: [CGPoint], _ first: Int, _ last: Int,
                                       _ u: [Double], _ tan1: CGPoint, _ tan2: CGPoint) -> Bez {
        let p0 = pts[first], p3 = pts[last]
        var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0

        for i in 0...(last - first) {
            let t = u[i]
            let b = 1 - t
            let b1 = 3 * b * b * t
            let b2 = 3 * b * t * t
            let b0 = b * b * b
            let b3 = t * t * t
            let a1 = scale(tan1, b1)
            let a2 = scale(tan2, b2)
            let base = add(scale(p0, b0 + b1), scale(p3, b2 + b3))
            let tmp = sub(pts[first + i], base)
            c00 += Double(dot(a1, a1))
            c01 += Double(dot(a1, a2))
            c11 += Double(dot(a2, a2))
            x0 += Double(dot(a1, tmp))
            x1 += Double(dot(a2, tmp))
        }

        let det = c00 * c11 - c01 * c01
        var alpha1 = 0.0
        var alpha2 = 0.0
        if abs(det) > 1e-12 {
            alpha1 = (x0 * c11 - x1 * c01) / det
            alpha2 = (c00 * x1 - c01 * x0) / det
        }
        let segLength = distance(p0, p3)
        let epsilon = 1e-6 * segLength
        if alpha1 < epsilon || alpha2 < epsilon {
            alpha1 = segLength / 3
            alpha2 = alpha1
        }
        return Bez(p0: p0, p1: add(p0, scale(tan1, alpha1)),
                   p2: add(p3, scale(tan2, alpha2)), p3: p3)
    }

    private static func maxError(_ pts: [CGPoint], _ first: Int, _ last: Int,
                                 _ bez: Bez, _ u: [Double]) -> (Double, Int) {
        var maxDistSq = 0.0
        var index = (first + last) / 2
        for i in 1..<(last - first) {
            let p = evaluate(bez, u[i])
            let d = sub(p, pts[first + i])
            let distSq = Double(d.x * d.x + d.y * d.y)
            if distSq >= maxDistSq {
                maxDistSq = distSq
                index = first + i
            }
        }
        return (maxDistSq, index)
    }

    private static func reparameterize(_ pts: [CGPoint], _ first: Int, _ last: Int,
                                       _ u: inout [Double], _ bez: Bez) -> Bool {
        for i in 0...(last - first) {
            u[i] = newtonRaphson(bez, pts[first + i], u[i])
        }
        for i in 1..<u.count where u[i] <= u[i - 1] {
            return false
        }
        return true
    }

    private static func newtonRaphson(_ bez: Bez, _ point: CGPoint, _ t: Double) -> Double {
        let q1 = [scale(sub(bez.p1, bez.p0), 3), scale(sub(bez.p2, bez.p1), 3), scale(sub(bez.p3, bez.p2), 3)]
        let q2 = [scale(sub(q1[1], q1[0]), 2), scale(sub(q1[2], q1[1]), 2)]
        let p = evaluate(bez, t)
        let d1 = quadraticPoint(q1[0], q1[1], q1[2], t)
        let d2 = lerp(q2[0], q2[1], t)
        let diff = sub(p, point)
        let denominator = Double(dot(d1, d1)) + Double(dot(diff, d2))
        guard abs(denominator) > 1e-12 else { return t }
        let next = t - Double(dot(diff, d1)) / denominator
        return min(1, max(0, next))
    }

    private static func chordLengthParameterize(_ pts: [CGPoint], _ first: Int, _ last: Int) -> [Double] {
        var u = [0.0]
        for i in (first + 1)...last {
            u.append(u[i - first - 1] + distance(pts[i], pts[i - 1]))
        }
        let total = u[u.count - 1]
        guard total > 0 else { return u }
        return u.map { $0 / total }
    }

    // MARK: - Emit

    private static func emit(_ subpaths: [SubPath]) -> String {
        var s = ""
        for sp in subpaths {
            s += "M\(fmt(sp.start.x)) \(fmt(sp.start.y))"
            for seg in sp.segments {
                switch seg {
                case .line(let p):
                    s += "L\(fmt(p.x)) \(fmt(p.y))"
                case .cubic(let c1, let c2, let p):
                    s += "C\(fmt(c1.x)) \(fmt(c1.y)) \(fmt(c2.x)) \(fmt(c2.y)) \(fmt(p.x)) \(fmt(p.y))"
                }
            }
            if sp.closed { s += "Z" }
        }
        return s
    }

    private static func fmt(_ value: CGFloat) -> String {
        let rounded = (Double(value) * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        var s = String(format: "%.2f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: - Geometry helpers

    private static func add(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    private static func sub(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    private static func scale(_ a: CGPoint, _ s: Double) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
    private static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }

    private static func normalize(_ v: CGPoint) -> CGPoint {
        let length = hypot(v.x, v.y)
        guard length > 1e-12 else { return .zero }
        return CGPoint(x: v.x / length, y: v.y / length)
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func quadraticPoint(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ t: Double) -> CGPoint {
        let ab = lerp(a, b, t)
        let bc = lerp(b, c, t)
        return lerp(ab, bc, t)
    }

    private static func cubicPoint(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint, _ t: Double) -> CGPoint {
        let a = lerp(p0, c1, t)
        let b = lerp(c1, c2, t)
        let c = lerp(c2, p3, t)
        return quadraticPoint(a, b, c, t)
    }

    private static func evaluate(_ bez: Bez, _ t: Double) -> CGPoint {
        cubicPoint(bez.p0, bez.p1, bez.p2, bez.p3, t)
    }
}
