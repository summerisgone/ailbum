import Foundation

public enum SiftDetector {}

extension SiftDetector {
    static let imgBorder = 5
    static let maxInterpSteps = 5

    public static func findExtrema(_ space: ScaleSpace, contrastThreshold: Double, edgeThreshold: Double) -> [SiftKeypoint] {
        let layers = space.layers
        let threshold = Float((0.5 * contrastThreshold / Double(layers) * 255).rounded(.down))
        var result: [SiftKeypoint] = []
        for o in 0..<space.dogs.count {
            let dogs = space.dogs[o]
            guard dogs.count == layers + 2 else { continue }
            let w = dogs[0].width, h = dogs[0].height
            guard w > 2 * imgBorder, h > 2 * imgBorder else { continue }
            for i in 1...layers {
                dogs[i].pixels.withUnsafeBufferPointer { cur in
                dogs[i - 1].pixels.withUnsafeBufferPointer { prev in
                dogs[i + 1].pixels.withUnsafeBufferPointer { next in
                    for r in imgBorder..<(h - imgBorder) {
                        for c in imgBorder..<(w - imgBorder) {
                            let v = cur[r * w + c]
                            guard abs(v) > threshold else { continue }
                            var isMax = v > 0, isMin = v < 0
                            if !isMax && !isMin { continue }
                            scan: for dy in -1...1 {
                                for dx in -1...1 {
                                    let j = (r + dy) * w + c + dx
                                    for n in [prev[j], cur[j], next[j]] {
                                        if isMax && v < n { isMax = false }
                                        if isMin && v > n { isMin = false }
                                    }
                                    if !isMax && !isMin { break scan }
                                }
                            }
                            guard isMax || isMin else { continue }
                            if let kp = refine(space, octave: o, layer: i, row: r, col: c,
                                               contrastThreshold: contrastThreshold, edgeThreshold: edgeThreshold) {
                                result.append(kp)
                            }
                        }
                    }
                }}}
            }
        }
        return result
    }

    private static func refine(_ space: ScaleSpace, octave o: Int, layer l: Int, row r0: Int, col c0: Int,
                               contrastThreshold: Double, edgeThreshold: Double) -> SiftKeypoint? {
        let layers = space.layers
        let dogs = space.dogs[o]
        let w = dogs[0].width, h = dogs[0].height
        let imgScale: Float = 1.0 / 255
        let derivScale = imgScale * 0.5
        let secondScale = imgScale
        let crossScale = imgScale * 0.25
        var layer = l, r = r0, c = c0
        var xi: Float = 0, xr: Float = 0, xc: Float = 0
        var dD = SIMD3<Float>(repeating: 0)
        var converged = false

        for _ in 0..<maxInterpSteps {
            let prev = dogs[layer - 1].pixels, cur = dogs[layer].pixels, next = dogs[layer + 1].pixels
            func at(_ p: [Float], _ dy: Int, _ dx: Int) -> Float { p[(r + dy) * w + c + dx] }
            let v2 = at(cur, 0, 0) * 2
            dD = SIMD3(
                (at(cur, 0, 1) - at(cur, 0, -1)) * derivScale,
                (at(cur, 1, 0) - at(cur, -1, 0)) * derivScale,
                (at(next, 0, 0) - at(prev, 0, 0)) * derivScale)
            let dxx = (at(cur, 0, 1) + at(cur, 0, -1) - v2) * secondScale
            let dyy = (at(cur, 1, 0) + at(cur, -1, 0) - v2) * secondScale
            let dss = (at(next, 0, 0) + at(prev, 0, 0) - v2) * secondScale
            let dxy = (at(cur, 1, 1) - at(cur, 1, -1) - at(cur, -1, 1) + at(cur, -1, -1)) * crossScale
            let dxs = (at(next, 0, 1) - at(next, 0, -1) - at(prev, 0, 1) + at(prev, 0, -1)) * crossScale
            let dys = (at(next, 1, 0) - at(next, -1, 0) - at(prev, 1, 0) + at(prev, -1, 0)) * crossScale
            guard let x = solve3(dxx, dxy, dxs, dyy, dys, dss, dD) else { return nil }
            xc = -x.x; xr = -x.y; xi = -x.z
            if abs(xi) < 0.5 && abs(xr) < 0.5 && abs(xc) < 0.5 { converged = true; break }
            let big = Float(Int32.max / 3)
            if abs(xi) > big || abs(xr) > big || abs(xc) > big { return nil }
            c += Int(xc.rounded()); r += Int(xr.rounded()); layer += Int(xi.rounded())
            if layer < 1 || layer > layers || c < imgBorder || c >= w - imgBorder || r < imgBorder || r >= h - imgBorder {
                return nil
            }
        }
        guard converged else { return nil }

        let cur = dogs[layer].pixels
        let val = cur[r * w + c]
        let t = dD.x * xc + dD.y * xr + dD.z * xi
        let contr = val * imgScale + t * 0.5
        if abs(Double(contr)) * Double(layers) < contrastThreshold { return nil }

        func at(_ dy: Int, _ dx: Int) -> Float { cur[(r + dy) * w + c + dx] }
        let v2 = val * 2
        let dxx = (at(0, 1) + at(0, -1) - v2) * secondScale
        let dyy = (at(1, 0) + at(-1, 0) - v2) * secondScale
        let dxy = (at(1, 1) - at(1, -1) - at(-1, 1) + at(-1, -1)) * crossScale
        let tr = dxx + dyy, det = dxx * dyy - dxy * dxy
        let e = Float(edgeThreshold)
        if det <= 0 || tr * tr * e >= (e + 1) * (e + 1) * det { return nil }

        let scale = Float(1 << o)
        var x = (Float(c) + xc) * scale
        var y = (Float(r) + xr) * scale
        var size = Float(space.sigma) * powf(2, (Float(layer) + xi) / Float(layers)) * scale * 2
        if space.firstOctave < 0 {
            let f = Float(1 << (-space.firstOctave))
            x /= f; y /= f; size /= f
        }
        return SiftKeypoint(x: x, y: y, size: size, angle: -1, response: abs(contr),
                            octave: o + space.firstOctave, layer: layer, subLayer: xi)
    }

    /// Solves H * x = b for symmetric H given by its entries; nil when singular.
    private static func solve3(_ a: Float, _ xy: Float, _ xs: Float, _ b: Float, _ ys: Float, _ c: Float,
                               _ d: SIMD3<Float>) -> SIMD3<Float>? {
        let m: [[Double]] = [[Double(a), Double(xy), Double(xs)],
                             [Double(xy), Double(b), Double(ys)],
                             [Double(xs), Double(ys), Double(c)]]
        let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        if abs(det) < 1e-30 { return nil }
        let rhs = [Double(d.x), Double(d.y), Double(d.z)]
        var out = [Double](repeating: 0, count: 3)
        for k in 0..<3 {
            var mk = m
            for row in 0..<3 { mk[row][k] = rhs[row] }
            let dk = mk[0][0] * (mk[1][1] * mk[2][2] - mk[1][2] * mk[2][1])
                - mk[0][1] * (mk[1][0] * mk[2][2] - mk[1][2] * mk[2][0])
                + mk[0][2] * (mk[1][0] * mk[2][1] - mk[1][1] * mk[2][0])
            out[k] = dk / det
        }
        return SIMD3(Float(out[0]), Float(out[1]), Float(out[2]))
    }
}
