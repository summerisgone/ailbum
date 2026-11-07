import Foundation

/// Spectral-residual saliency, port of `_subject_from_saliency` (src/ailbum/cv/aesthetics.py).
public enum Saliency {
    // MARK: FFT

    /// Radix-2 plan with a precomputed twiddle table.
    private struct Pow2 {
        let n: Int
        let cosT: [Double], sinT: [Double]
        init(_ n: Int) {
            self.n = n
            cosT = (0..<max(n / 2, 1)).map { cos(-2.0 * Double.pi * Double($0) / Double(n)) }
            sinT = (0..<max(n / 2, 1)).map { sin(-2.0 * Double.pi * Double($0) / Double(n)) }
        }

        func run(_ re: inout [Double], _ im: inout [Double]) {
            guard n > 1 else { return }
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    cosT.withUnsafeBufferPointer { c in
                        sinT.withUnsafeBufferPointer { s in
                            Pow2.kernel(n, r.baseAddress!, i.baseAddress!, c.baseAddress!, s.baseAddress!)
                        }
                    }
                }
            }
        }

        // Kept free of closures so @_optimize applies even in debug builds.
        @_optimize(speed)
        static func kernel(_ n: Int, _ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>,
                           _ cosT: UnsafePointer<Double>, _ sinT: UnsafePointer<Double>) {
            var j = 0
            for i in 1..<n {
                var bit = n >> 1
                while j & bit != 0 { j ^= bit; bit >>= 1 }
                j ^= bit
                if i < j {
                    let tr = re[i]; re[i] = re[j]; re[j] = tr
                    let ti = im[i]; im[i] = im[j]; im[j] = ti
                }
            }
            var len = 2
            while len <= n {
                let half = len / 2, step = n / len
                var start = 0
                while start < n {
                    for k in 0..<half {
                        let wr = cosT[k * step], wi = sinT[k * step]
                        let a = start + k, b = a + half
                        let tr = re[b] * wr - im[b] * wi
                        let ti = re[b] * wi + im[b] * wr
                        re[b] = re[a] - tr; im[b] = im[a] - ti
                        re[a] += tr; im[a] += ti
                    }
                    start += len
                }
                len <<= 1
            }
        }
    }

    /// Forward unnormalised DFT plan for one length; Bluestein chirp-z for non-power-of-two lengths.
    private struct Line {
        let n: Int
        let m: Int
        let pow: Pow2
        var wr: [Double] = [], wi: [Double] = []
        var bR: [Double] = [], bI: [Double] = []

        init(_ n: Int) {
            self.n = n
            if n <= 1 || n & (n - 1) == 0 { m = n; pow = Pow2(n); return }
            var m = 1
            while m < 2 * n - 1 { m <<= 1 }
            self.m = m
            pow = Pow2(m)
            wr = [Double](repeating: 0, count: n); wi = wr
            for k in 0..<n {
                let ang = -Double.pi * Double((k * k) % (2 * n)) / Double(n)
                wr[k] = cos(ang); wi[k] = sin(ang)
            }
            bR = [Double](repeating: 0, count: m); bI = bR
            bR[0] = wr[0]; bI[0] = -wi[0]
            for k in 1..<n {
                bR[k] = wr[k]; bI[k] = -wi[k]
                bR[m - k] = wr[k]; bI[m - k] = -wi[k]
            }
            pow.run(&bR, &bI)
        }

        @_optimize(speed)
        func run(_ re: inout [Double], _ im: inout [Double]) {
            if n <= 1 { return }
            if wr.isEmpty { pow.run(&re, &im); return }
            var ar = [Double](repeating: 0, count: m), ai = ar
            for k in 0..<n {
                ar[k] = re[k] * wr[k] - im[k] * wi[k]
                ai[k] = re[k] * wi[k] + im[k] * wr[k]
            }
            pow.run(&ar, &ai)
            for k in 0..<m {
                let r = ar[k] * bR[k] - ai[k] * bI[k]
                let i = ar[k] * bI[k] + ai[k] * bR[k]
                ar[k] = r; ai[k] = -i // conjugate for inverse via conj trick
            }
            pow.run(&ar, &ai)
            let s = 1.0 / Double(m)
            for k in 0..<n {
                let cr = ar[k] * s, ci = -ai[k] * s
                re[k] = cr * wr[k] - ci * wi[k]
                im[k] = cr * wi[k] + ci * wr[k]
            }
        }
    }

    /// 2-D DFT (numpy `fft2` / `ifft2`; the inverse is scaled by 1/(w*h)), row-major.
    @_optimize(speed)
    public static func dft2(_ re: [Double], _ im: [Double], width: Int, height: Int, inverse: Bool) -> ([Double], [Double]) {
        var outR = re, outI = inverse ? im.map { -$0 } : im
        let rowPlan = Line(width), colPlan = Line(height)
        var r = [Double](repeating: 0, count: width), i = r
        for y in 0..<height {
            for x in 0..<width { r[x] = outR[y * width + x]; i[x] = outI[y * width + x] }
            rowPlan.run(&r, &i)
            for x in 0..<width { outR[y * width + x] = r[x]; outI[y * width + x] = i[x] }
        }
        var cr = [Double](repeating: 0, count: height), ci = cr
        for x in 0..<width {
            for y in 0..<height { cr[y] = outR[y * width + x]; ci[y] = outI[y * width + x] }
            colPlan.run(&cr, &ci)
            for y in 0..<height { outR[y * width + x] = cr[y]; outI[y * width + x] = ci[y] }
        }
        if inverse {
            let s = 1.0 / Double(width * height)
            for k in 0..<outR.count { outR[k] *= s; outI[k] = -outI[k] * s }
        }
        return (outR, outI)
    }

    // MARK: helpers

    /// numpy.quantile, linear interpolation.
    static func quantile(_ values: [Double], _ q: Double) -> Double {
        let s = values.sorted()
        let pos = q * Double(s.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = min(lo + 1, s.count - 1)
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    /// Bounding box of the largest 8-connected component (first in raster order on ties).
    static func largestComponent(_ mask: [Bool], width: Int, height: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        var seen = [Bool](repeating: false, count: mask.count)
        var best: (area: Int, box: (x: Int, y: Int, w: Int, h: Int))?
        for start in 0..<mask.count where mask[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var area = 0
            var x0 = width, y0 = height, x1 = -1, y1 = -1
            while let p = stack.popLast() {
                let px = p % width, py = p / width
                area += 1
                x0 = min(x0, px); x1 = max(x1, px); y0 = min(y0, py); y1 = max(y1, py)
                for dy in -1...1 { for dx in -1...1 {
                    let nx = px + dx, ny = py + dy
                    if nx < 0 || ny < 0 || nx >= width || ny >= height { continue }
                    let q = ny * width + nx
                    if mask[q] && !seen[q] { seen[q] = true; stack.append(q) }
                } }
            }
            if best == nil || area > best!.area {
                best = (area, (x0, y0, x1 - x0 + 1, y1 - y0 + 1))
            }
        }
        return best?.box
    }

    private static func reflect101(_ i: Int, _ n: Int) -> Int {
        if n == 1 { return 0 }
        var i = i
        while i < 0 || i >= n { i = i < 0 ? -i : 2 * n - 2 - i }
        return i
    }

    /// Separable filter with REFLECT_101 borders.
    @_optimize(speed)
    private static func filter(_ src: [Double], width: Int, height: Int, kernel: [Double]) -> [Double] {
        let r = kernel.count / 2, kc = kernel.count
        let xi = (0..<width).map { x in (0..<kc).map { reflect101(x + $0 - r, width) } }
        let yi = (0..<height).map { y in (0..<kc).map { reflect101(y + $0 - r, height) * width } }
        var tmp = src
        var out = src
        src.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { t in
                for y in 0..<height {
                    let row = y * width
                    for x in 0..<width {
                        var a = 0.0
                        let idx = xi[x]
                        for k in 0..<kc { a += kernel[k] * s[row + idx[k]] }
                        t[row + x] = a
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<height {
                    let idx = yi[y]
                    for x in 0..<width {
                        var a = 0.0
                        for k in 0..<kc { a += kernel[k] * t[idx[k] + x] }
                        o[y * width + x] = a
                    }
                }
            }
        }
        return out
    }

    // MARK: subject

    public static func subject(_ image: RGBImage, maxSide: Int) -> (SubjectRecord?, Double) {
        let (resized, _) = Resize.forAnalysis(image, maxSide: maxSide)
        let w = resized.width, h = resized.height, n = w * h
        var gray = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let r: Int = Int(resized.pixels[i * 3])
            let g: Int = Int(resized.pixels[i * 3 + 1])
            let b: Int = Int(resized.pixels[i * 3 + 2])
            let lum: Int = (r * 4899 + g * 9617 + b * 1868 + 8192) >> 14
            gray[i] = Double(lum) / 255.0
        }
        let mean = gray.reduce(0, +) / Double(n)
        var sq = 0.0
        for v in gray { sq += (v - mean) * (v - mean) }
        let variance = sq / Double(n)
        if variance.squareRoot() < 1e-4 { return (nil, 0.0) }

        let (fr, fi) = dft2(gray, [Double](repeating: 0, count: n), width: w, height: h, inverse: false)
        var logAmp = [Double](repeating: 0, count: n)
        for i in 0..<n { logAmp[i] = log(hypot(fr[i], fi[i]) + 1e-8) }
        let smooth = filter(logAmp, width: w, height: h, kernel: [1.0 / 3, 1.0 / 3, 1.0 / 3])
        var er = [Double](repeating: 0, count: n), ei = er
        for i in 0..<n {
            let mag = exp(logAmp[i] - smooth[i])
            let ang = atan2(fi[i], fr[i])
            er[i] = mag * cos(ang); ei[i] = mag * sin(ang)
        }
        let (ir, ii) = dft2(er, ei, width: w, height: h, inverse: true)
        var sal = (0..<n).map { ir[$0] * ir[$0] + ii[$0] * ii[$0] }
        var kern = [Double](repeating: 0, count: 9)
        for k in 0..<9 {
            let d = Double(k - 4)
            kern[k] = exp(-(d * d) / 12.5)
        }
        let ksum = kern.reduce(0, +)
        kern = kern.map { $0 / ksum }
        sal = filter(sal, width: w, height: h, kernel: kern)
        let lo = sal.min()!
        sal = sal.map { $0 - lo }
        let peak = sal.max()!
        if peak <= 1e-8 { return (nil, 0.0) }
        sal = sal.map { $0 / peak }

        let border = max(1, Int((Double(min(w, h)) * 0.04).rounded(.toNearestOrEven)))
        var edgeSum = 0.0
        for y in 0..<h { for x in 0..<w where y < border || y >= h - border || x < border || x >= w - border {
            edgeSum += sal[y * w + x]
        } }
        let edgeEnergy = edgeSum / max(sal.reduce(0, +), 1e-8)
        let edgeRisk = min(max(edgeEnergy / 0.22, 0), 1)

        let cutoff = max(0.35, quantile(sal, 0.82))
        let mask = sal.map { $0 >= cutoff }
        guard let box = largestComponent(mask, width: w, height: h) else { return (nil, edgeRisk) }
        return (normalizedSubject(box.x, box.y, box.w, box.h, w, h, "saliency"), edgeRisk)
    }

    static func normalizedSubject(_ x: Int, _ y: Int, _ bw: Int, _ bh: Int, _ iw: Int, _ ih: Int, _ source: String) -> SubjectRecord {
        func c(_ v: Double) -> Double { min(max(v, 0), 1) }
        func r4(_ v: Double) -> Double { (v * 10000).rounded(.toNearestOrEven) / 10000 }
        let b = [c(Double(x) / Double(iw)), c(Double(y) / Double(ih)), c(Double(bw) / Double(iw)), c(Double(bh) / Double(ih))]
        let center = (b[0] + b[2] / 2, b[1] + b[3] / 2)
        return SubjectRecord(bbox: SIMD4(r4(b[0]), r4(b[1]), r4(b[2]), r4(b[3])),
                             center: SIMD2(r4(center.0), r4(center.1)), source: source)
    }
}
