//
//  ShapeBrushGeometry.swift
//  VTraceGUI
//
//  Turns a round brush gesture into filled vector geometry, then combines it
//  with one traced shape using Core Graphics' path boolean operations.
//

import Foundation
import CoreGraphics

nonisolated enum ShapeBrushOperation: String, Sendable {
    case add
    case subtract
}

nonisolated enum ShapeBrushGeometry {

    /// Applies one round brush gesture to `d`.
    ///
    /// `points` and `diameter` are in the root SVG's user coordinate system.
    /// `pathTransform` maps the path's local `d` coordinates into that root
    /// coordinate system (vtracer normally emits a translate per path).
    /// The returned path is transformed back into the original path-local
    /// coordinates so the existing SVG transform can remain untouched.
    static func apply(to d: String,
                      points: [CGPoint],
                      diameter: CGFloat,
                      pathTransform: CGAffineTransform,
                      operation: ShapeBrushOperation) -> String? {
        guard diameter.isFinite, diameter > 0,
              pathTransform.isFinite,
              abs(pathTransform.determinant) > 1e-12,
              let subpaths = SVGSimplifier.parsePathData(d) else {
            return nil
        }

        let cleanPoints = deduplicated(points)
        guard !cleanPoints.isEmpty else { return nil }

        let localPath = makePath(from: subpaths)
        let rootPath = CGMutablePath()
        rootPath.addPath(localPath, transform: pathTransform)
        let normalizedRootPath = rootPath.normalized(using: .winding)
        let brushPath = makeBrush(points: cleanPoints, diameter: diameter)

        let result: CGPath
        switch operation {
        case .add:
            // A dab wholly inside the shape changes no filled pixels.
            guard !brushPath.subtracting(normalizedRootPath, using: .winding).isEmpty else {
                return d
            }
            result = normalizedRootPath.union(brushPath, using: .winding)
        case .subtract:
            // Avoid rewriting an untouched shape merely to normalize it.
            guard !brushPath.intersection(normalizedRootPath, using: .winding).isEmpty else {
                return d
            }
            result = normalizedRootPath.subtracting(brushPath, using: .winding)
        }

        if result.isEmpty { return "" }
        return emit(result, transform: pathTransform.inverted())
    }

    private static func makePath(from subpaths: [SVGSimplifier.SubPath]) -> CGPath {
        let path = CGMutablePath()
        for subpath in subpaths {
            path.move(to: subpath.start)
            for segment in subpath.segments {
                switch segment {
                case .line(let point):
                    path.addLine(to: point)
                case .cubic(let control1, let control2, let point):
                    path.addCurve(to: point, control1: control1, control2: control2)
                }
            }
            if subpath.closed { path.closeSubpath() }
        }
        return path
    }

    private static func makeBrush(points: [CGPoint], diameter: CGFloat) -> CGPath {
        let radius = diameter / 2
        if points.count == 1 {
            let point = points[0]
            let dot = CGMutablePath()
            dot.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                      width: diameter, height: diameter))
            return dot
        }

        let centerline = CGMutablePath()
        centerline.move(to: points[0])
        for point in points.dropFirst() {
            centerline.addLine(to: point)
        }
        return centerline.copy(strokingWithWidth: diameter,
                               lineCap: .round,
                               lineJoin: .round,
                               miterLimit: 2)
    }

    /// Mouse streams often repeat coordinates. Removing those duplicates keeps
    /// Core Graphics from seeing zero-length segments and bounds boolean work.
    private static func deduplicated(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        result.reserveCapacity(points.count)
        for point in points where point.x.isFinite && point.y.isFinite {
            if let previous = result.last,
               hypot(point.x - previous.x, point.y - previous.y) < 0.001 {
                continue
            }
            result.append(point)
        }
        return result
    }

    /// Emits only M/L/C/Z. Core Graphics can occasionally return a quadratic
    /// element, so convert it to an equivalent cubic to keep the app's existing
    /// SVG parser and anchor editor on one compact command set.
    private static func emit(_ path: CGPath, transform: CGAffineTransform) -> String {
        var output = ""
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero

        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                let point = element.points[0].applying(transform)
                output += "M\(fmt(point.x)) \(fmt(point.y))"
                current = point
                subpathStart = point

            case .addLineToPoint:
                let point = element.points[0].applying(transform)
                output += "L\(fmt(point.x)) \(fmt(point.y))"
                current = point

            case .addQuadCurveToPoint:
                let control = element.points[0].applying(transform)
                let point = element.points[1].applying(transform)
                let control1 = CGPoint(
                    x: current.x + (control.x - current.x) * 2 / 3,
                    y: current.y + (control.y - current.y) * 2 / 3
                )
                let control2 = CGPoint(
                    x: point.x + (control.x - point.x) * 2 / 3,
                    y: point.y + (control.y - point.y) * 2 / 3
                )
                output += cubic(control1, control2, point)
                current = point

            case .addCurveToPoint:
                let control1 = element.points[0].applying(transform)
                let control2 = element.points[1].applying(transform)
                let point = element.points[2].applying(transform)
                output += cubic(control1, control2, point)
                current = point

            case .closeSubpath:
                output += "Z"
                current = subpathStart

            @unknown default:
                break
            }
        }
        return output
    }

    private static func cubic(_ control1: CGPoint, _ control2: CGPoint,
                              _ point: CGPoint) -> String {
        "C\(fmt(control1.x)) \(fmt(control1.y)) " +
        "\(fmt(control2.x)) \(fmt(control2.y)) " +
        "\(fmt(point.x)) \(fmt(point.y))"
    }

    private static func fmt(_ value: CGFloat) -> String {
        let value = abs(value) < 0.0005 ? 0 : value
        let rounded = (Double(value) * 1_000).rounded() / 1_000
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var string = String(format: "%.3f", rounded)
        while string.hasSuffix("0") { string.removeLast() }
        if string.hasSuffix(".") { string.removeLast() }
        return string
    }
}

private extension CGAffineTransform {
    nonisolated var determinant: CGFloat { a * d - b * c }
    nonisolated var isFinite: Bool {
        a.isFinite && b.isFinite && c.isFinite &&
        d.isFinite && tx.isFinite && ty.isFinite
    }
}
