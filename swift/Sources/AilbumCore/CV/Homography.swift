import Foundation

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

public enum Homography {
    typealias Mat = [Double]  // 3x3 row-major

    /// RANSAC inlier mask (OpenCV findHomography semantics), or nil if no model is found.
    public static func ransacInliers(_ src: [SIMD2<Float>], _ dst: [SIMD2<Float>],
                                     threshold: Float, seed: UInt64) -> [Bool]? {
        let n = src.count
        guard n >= 4, dst.count == n else { return nil }
        let thr2 = Double(threshold) * Double(threshold)
        var rng = SplitMix64(state: seed)
        var bestCount = 0
        var bestMask: [Bool] = []
        var maxIter = 2000
        var iter = 0
        while iter < maxIter {
            iter += 1
            var idx = [Int]()
            while idx.count < 4 { // distinct indices
                let k = Int(rng.next() % UInt64(n))
                if !idx.contains(k) { idx.append(k) }
            }
            let s = idx.map { src[$0] }, d = idx.map { dst[$0] }
            if hasCollinearTriple(s) || hasCollinearTriple(d) { continue }
            guard let h = fit(s, d) else { continue }
            let mask = inlierMask(h, src, dst, thr2)
            let count = mask.reduce(0) { $0 + ($1 ? 1 : 0) }
            if count > bestCount {
                bestCount = count
                bestMask = mask
                let ratio = Double(count) / Double(n)
                let denom = log(max(1 - pow(ratio, 4), Double.leastNormalMagnitude))
                let needed = denom == 0 ? maxIter : Int(ceil(log(1 - 0.995) / denom))
                maxIter = min(maxIter, max(needed, 1))
            }
        }
        guard bestCount >= 4 else { return nil }
        let s = zip(bestMask, src).filter { $0.0 }.map { $0.1 }
        let d = zip(bestMask, dst).filter { $0.0 }.map { $0.1 }
        if let h = fit(s, d) {
            let refit = inlierMask(h, src, dst, thr2)
            if refit.filter({ $0 }).count >= 4 { return refit }
        }
        return bestMask
    }

    static func hasCollinearTriple(_ p: [SIMD2<Float>]) -> Bool {
        for i in 0..<p.count {
            for j in (i + 1)..<p.count {
                for k in (j + 1)..<p.count {
                    let a = SIMD2<Double>(p[j] - p[i]), b = SIMD2<Double>(p[k] - p[i])
                    let cr = a.x * b.y - a.y * b.x
                    if cr * cr <= 1e-8 * (a.x * a.x + a.y * a.y) * (b.x * b.x + b.y * b.y) { return true }
                }
            }
        }
        return false
    }

    static func inlierMask(_ h: Mat, _ src: [SIMD2<Float>], _ dst: [SIMD2<Float>], _ thr2: Double) -> [Bool] {
        (0..<src.count).map { i in
            let x = Double(src[i].x), y = Double(src[i].y)
            let w = h[6] * x + h[7] * y + h[8]
            guard abs(w) > 1e-12 else { return false }
            let dx = (h[0] * x + h[1] * y + h[2]) / w - Double(dst[i].x)
            let dy = (h[3] * x + h[4] * y + h[5]) / w - Double(dst[i].y)
            return dx * dx + dy * dy <= thr2
        }
    }

    /// Hartley-normalised DLT; smallest eigenvector of AtA via Jacobi.
    static func fit(_ src: [SIMD2<Float>], _ dst: [SIMD2<Float>]) -> Mat? {
        guard let (ts, s) = normalization(src), let (td, d) = normalization(dst) else { return nil }
        var ata = [Double](repeating: 0, count: 81)
        for i in 0..<s.count {
            let (x, y) = s[i], (u, v) = d[i]
            let r1: [Double] = [-x, -y, -1, 0, 0, 0, u * x, u * y, u]
            let r2: [Double] = [0, 0, 0, -x, -y, -1, v * x, v * y, v]
            for r in [r1, r2] {
                for a in 0..<9 { for b in 0..<9 { ata[a * 9 + b] += r[a] * r[b] } }
            }
        }
        let hn = smallestEigenvector(ata, 9)
        // H = Td^-1 * Hn * Ts
        let tdInv: Mat = [1 / td.0, 0, td.1, 0, 1 / td.0, td.2, 0, 0, 1]
        let tsM: Mat = [ts.0, 0, -ts.0 * ts.1, 0, ts.0, -ts.0 * ts.2, 0, 0, 1]
        var h = mul(tdInv, mul(hn, tsM))
        guard abs(h[8]) > 1e-12 else { return nil }
        let k = 1 / h[8]
        h = h.map { $0 * k }
        return h.allSatisfy({ $0.isFinite }) ? h : nil
    }

    // Returns (scale, cx, cy) as a tuple plus normalised points. Transform: p' = scale*(p - c).
    private static func normalization(_ p: [SIMD2<Float>])
        -> ((Double, Double, Double), [(Double, Double)])? {
        let n = Double(p.count)
        let cx = p.reduce(0.0) { $0 + Double($1.x) } / n
        let cy = p.reduce(0.0) { $0 + Double($1.y) } / n
        let mean = p.reduce(0.0) { $0 + hypot(Double($1.x) - cx, Double($1.y) - cy) } / n
        guard mean > 1e-12 else { return nil }
        let sc = 2.0.squareRoot() / mean
        return ((sc, cx, cy), p.map { (sc * (Double($0.x) - cx), sc * (Double($0.y) - cy)) })
    }

    private static func mul(_ a: Mat, _ b: Mat) -> Mat {
        var c = Mat(repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { c[i * 3 + j] += a[i * 3 + k] * b[k * 3 + j] } } }
        return c
    }

    private static func smallestEigenvector(_ m: [Double], _ n: Int) -> [Double] {
        var a = m
        var v = [Double](repeating: 0, count: n * n)
        for i in 0..<n { v[i * n + i] = 1 }
        for _ in 0..<60 {
            var off = 0.0
            for p in 0..<n { for q in (p + 1)..<n { off += a[p * n + q] * a[p * n + q] } }
            if off < 1e-24 { break }
            for p in 0..<(n - 1) {
                for q in (p + 1)..<n {
                    let apq = a[p * n + q]
                    if abs(apq) < 1e-300 { continue }
                    let theta = (a[q * n + q] - a[p * n + p]) / (2 * apq)
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot(), s = t * c
                    for k in 0..<n {
                        let akp = a[k * n + p], akq = a[k * n + q]
                        a[k * n + p] = c * akp - s * akq
                        a[k * n + q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p * n + k], aqk = a[q * n + k]
                        a[p * n + k] = c * apk - s * aqk
                        a[q * n + k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k * n + p], vkq = v[k * n + q]
                        v[k * n + p] = c * vkp - s * vkq
                        v[k * n + q] = s * vkp + c * vkq
                    }
                }
            }
        }
        var best = 0
        for i in 1..<n where a[i * n + i] < a[best * n + best] { best = i }
        return (0..<n).map { v[$0 * n + best] }
    }
}
