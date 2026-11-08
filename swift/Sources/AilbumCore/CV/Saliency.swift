import Foundation
import Accelerate

/// Spectral-residual saliency, port of `_subject_from_saliency` (src/ailbum/cv/aesthetics.py).
public enum Saliency {
    // MARK: FFT

    /// Power-of-two FFT through Accelerate, one cached vDSP setup per length.
    private final class Pow2 {
        let n: Int
        private let log2n: vDSP_Length
        private let setup: FFTSetupD?
        // Tiny lengths are outside vDSP's range: plain DFT.
        private static let minVDSP = 8

        private static let cacheLock = NSLock()
        nonisolated(unsafe) private static var cache: [Int: Pow2] = [:]

        static func plan(_ n: Int) -> Pow2 {
            cacheLock.lock(); defer { cacheLock.unlock() }
            if let p = cache[n] { return p }
            let p = Pow2(n)
            cache[n] = p
            return p
        }

        private init(_ n: Int) {
            self.n = n
            log2n = vDSP_Length(n > 1 ? Int.bitWidth - 1 - n.leadingZeroBitCount : 0)
            setup = n >= Pow2.minVDSP ? vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) : nil
        }

        /// In-place forward unnormalised transform of `n` split-complex values.
        func run(_ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>) {
            guard n > 1 else { return }
            if let setup {
                var sc = DSPDoubleSplitComplex(realp: re, imagp: im)
                vDSP_fft_zipD(setup, &sc, 1, log2n, FFTDirection(kFFTDirection_Forward))
                return
            }
            var tmpR = [Double](repeating: 0, count: n), tmpI = tmpR
            for k in 0..<n {
                var sr = 0.0, si = 0.0
                for t in 0..<n {
                    let ang = -2.0 * Double.pi * Double((k * t) % n) / Double(n)
                    sr += re[t] * cos(ang) - im[t] * sin(ang)
                    si += re[t] * sin(ang) + im[t] * cos(ang)
                }
                tmpR[k] = sr; tmpI[k] = si
            }
            for k in 0..<n { re[k] = tmpR[k]; im[k] = tmpI[k] }
        }
    }

    /// Forward unnormalised DFT plan for one length; Bluestein chirp-z for non-power-of-two lengths.
    private final class Line {
        let n: Int
        let m: Int
        let pow: Pow2
        var wr: [Double] = [], wi: [Double] = []
        var bR: [Double] = [], bI: [Double] = []

        init(_ n: Int) {
            self.n = n
            if n <= 1 || n & (n - 1) == 0 { m = n; pow = Pow2.plan(n); return }
            var m = 1
            while m < 2 * n - 1 { m <<= 1 }
            self.m = m
            pow = Pow2.plan(m)
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
            bR.withUnsafeMutableBufferPointer { r in
                bI.withUnsafeMutableBufferPointer { i in pow.run(r.baseAddress!, i.baseAddress!) }
            }
        }

        /// In-place forward transform of `n` split-complex values.
        func run(_ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>) {
            if n <= 1 { return }
            if wr.isEmpty { pow.run(re, im); return }
            let n = self.n, m = self.m
            var ar = [Double](repeating: 0, count: m), ai = ar
            var tr = [Double](repeating: 0, count: m), ti = tr
            wr.withUnsafeMutableBufferPointer { wrp in
            wi.withUnsafeMutableBufferPointer { wip in
            bR.withUnsafeMutableBufferPointer { brp in
            bI.withUnsafeMutableBufferPointer { bip in
            ar.withUnsafeMutableBufferPointer { arp in
            ai.withUnsafeMutableBufferPointer { aip in
            tr.withUnsafeMutableBufferPointer { trp in
            ti.withUnsafeMutableBufferPointer { tip in
                var x = DSPDoubleSplitComplex(realp: re, imagp: im)
                var w = DSPDoubleSplitComplex(realp: wrp.baseAddress!, imagp: wip.baseAddress!)
                var b = DSPDoubleSplitComplex(realp: brp.baseAddress!, imagp: bip.baseAddress!)
                var a = DSPDoubleSplitComplex(realp: arp.baseAddress!, imagp: aip.baseAddress!)
                var t = DSPDoubleSplitComplex(realp: trp.baseAddress!, imagp: tip.baseAddress!)
                // a[0..<n] = x * chirp
                vDSP_zvmulD(&x, 1, &w, 1, &a, 1, vDSP_Length(n), 1)
                pow.run(arp.baseAddress!, aip.baseAddress!)
                // t = a * B, then conjugate for the inverse transform
                vDSP_zvmulD(&a, 1, &b, 1, &t, 1, vDSP_Length(m), 1)
                vDSP_vnegD(tip.baseAddress!, 1, tip.baseAddress!, 1, vDSP_Length(m))
                pow.run(trp.baseAddress!, tip.baseAddress!)
                // x = conj(t) / m * chirp
                var s = 1.0 / Double(m)
                vDSP_vsmulD(trp.baseAddress!, 1, &s, trp.baseAddress!, 1, vDSP_Length(n))
                vDSP_vsmulD(tip.baseAddress!, 1, &s, tip.baseAddress!, 1, vDSP_Length(n))
                vDSP_vnegD(tip.baseAddress!, 1, tip.baseAddress!, 1, vDSP_Length(n))
                vDSP_zvmulD(&t, 1, &w, 1, &x, 1, vDSP_Length(n), 1)
            }}}}}}}}
        }
    }

    /// 2-D DFT (numpy `fft2` / `ifft2`; the inverse is scaled by 1/(w*h)), row-major.
    public static func dft2(_ re: [Double], _ im: [Double], width: Int, height: Int, inverse: Bool) -> ([Double], [Double]) {
        let n = width * height
        var outR = re, outI = im
        if inverse { vDSP_vnegD(im, 1, &outI, 1, vDSP_Length(n)) }
        let rowPlan = Line(width), colPlan = Line(height)
        var tR = [Double](repeating: 0, count: n), tI = tR
        outR.withUnsafeMutableBufferPointer { rp in
        outI.withUnsafeMutableBufferPointer { ip in
        tR.withUnsafeMutableBufferPointer { trp in
        tI.withUnsafeMutableBufferPointer { tip in
            let rb = rp.baseAddress!, ib = ip.baseAddress!, tb = trp.baseAddress!, ub = tip.baseAddress!
            for y in 0..<height { rowPlan.run(rb + y * width, ib + y * width) }
            // columns become contiguous rows of the transposed matrix
            vDSP_mtransD(rb, 1, tb, 1, vDSP_Length(width), vDSP_Length(height))
            vDSP_mtransD(ib, 1, ub, 1, vDSP_Length(width), vDSP_Length(height))
            for x in 0..<width { colPlan.run(tb + x * height, ub + x * height) }
            vDSP_mtransD(tb, 1, rb, 1, vDSP_Length(height), vDSP_Length(width))
            vDSP_mtransD(ub, 1, ib, 1, vDSP_Length(height), vDSP_Length(width))
            if inverse {
                var s = 1.0 / Double(n), ns = -s
                vDSP_vsmulD(rb, 1, &s, rb, 1, vDSP_Length(n))
                vDSP_vsmulD(ib, 1, &ns, ib, 1, vDSP_Length(n))
            }
        } } } }
        return (outR, outI)
    }

    // MARK: helpers

    /// numpy.quantile, linear interpolation.
    static func quantile(_ values: [Double], _ q: Double) -> Double {
        var s = values
        vDSP_vsortD(&s, vDSP_Length(s.count), 1)
        let pos = q * Double(s.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = min(lo + 1, s.count - 1)
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    /// Bounding box of the largest 8-connected component (first in raster order on ties).
    @_optimize(speed)
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
    private static func filter(_ src: [Double], width: Int, height: Int, kernel: [Double]) -> [Double] {
        let kc = kernel.count, r = kc / 2
        var tmp = [Double](repeating: 0, count: src.count)
        var out = tmp
        var padded = [Double](repeating: 0, count: width + 2 * r)
        src.withUnsafeBufferPointer { s in
        tmp.withUnsafeMutableBufferPointer { t in
        out.withUnsafeMutableBufferPointer { o in
        padded.withUnsafeMutableBufferPointer { p in
        kernel.withUnsafeBufferPointer { kp in
            let sb = s.baseAddress!, tb = t.baseAddress!, ob = o.baseAddress!, pb = p.baseAddress!, kb = kp.baseAddress!
            for y in 0..<height {
                let row = sb + y * width
                (pb + r).update(from: row, count: width)
                for i in 0..<r {
                    pb[i] = row[reflect101(i - r, width)]
                    pb[width + r + i] = row[reflect101(width + i, width)]
                }
                vDSP_convD(pb, 1, kb, 1, tb + y * width, 1, vDSP_Length(width), vDSP_Length(kc))
            }
            for y in 0..<height {
                let dst = ob + y * width
                for k in 0..<kc {
                    var kv = kb[k]
                    let from = tb + reflect101(y + k - r, height) * width
                    if k == 0 { vDSP_vsmulD(from, 1, &kv, dst, 1, vDSP_Length(width)) }
                    else { vDSP_vsmaD(from, 1, &kv, dst, 1, dst, 1, vDSP_Length(width)) }
                }
            }
        } } } } }
        return out
    }

    // Per-pixel stages on Accelerate: generic Swift loops are unoptimised in debug builds.
    private static func grayscale(_ pixels: [UInt8], _ n: Int) -> [Double] {
        let len = vDSP_Length(n)
        var r = [Double](repeating: 0, count: n), g = r, b = r
        pixels.withUnsafeBufferPointer { p in
            vDSP_vfltu8D(p.baseAddress!, 3, &r, 1, len)
            vDSP_vfltu8D(p.baseAddress! + 1, 3, &g, 1, len)
            vDSP_vfltu8D(p.baseAddress! + 2, 3, &b, 1, len)
        }
        // lum = (r*4899 + g*9617 + b*1868 + 8192) >> 14, exact in doubles
        var acc = r, acc2 = r
        var k = 4899.0
        vDSP_vsmulD(r, 1, &k, &acc, 1, len)
        k = 9617.0
        vDSP_vsmaD(g, 1, &k, acc, 1, &acc2, 1, len)
        k = 1868.0
        vDSP_vsmaD(b, 1, &k, acc2, 1, &acc, 1, len)
        var add = 8192.0, scale = 1.0 / 16384.0, div = 255.0
        vDSP_vsaddD(acc, 1, &add, &acc2, 1, len)
        vDSP_vsmulD(acc2, 1, &scale, &acc, 1, len)
        var cnt = Int32(n)
        vvfloor(&acc2, acc, &cnt)
        vDSP_vsdivD(acc2, 1, &div, &acc, 1, len)
        return acc
    }

    private static func stddev(_ gray: [Double]) -> Double {
        let len = vDSP_Length(gray.count)
        var mean = 0.0
        vDSP_meanvD(gray, 1, &mean, len)
        var neg = -mean, centered = gray, sq = 0.0
        vDSP_vsaddD(gray, 1, &neg, &centered, 1, len)
        vDSP_svesqD(centered, 1, &sq, len)
        return (sq / Double(gray.count)).squareRoot()
    }

    private static func logAmplitude(_ fr: [Double], _ fi: [Double]) -> [Double] {
        let len = vDSP_Length(fr.count)
        var mag = fr, out = fr, eps = 1e-8
        var cnt = Int32(fr.count)
        vDSP_vdistD(fr, 1, fi, 1, &mag, 1, len)
        vDSP_vsaddD(mag, 1, &eps, &out, 1, len)
        vvlog(&mag, out, &cnt)
        return mag
    }

    private static func residual(_ logAmp: [Double], _ smooth: [Double], _ fr: [Double], _ fi: [Double]) -> ([Double], [Double]) {
        let len = vDSP_Length(logAmp.count)
        var cnt = Int32(logAmp.count)
        var diff = logAmp, mag = logAmp, ang = logAmp, sn = logAmp, cs = logAmp
        vDSP_vsubD(smooth, 1, logAmp, 1, &diff, 1, len)
        vvexp(&mag, diff, &cnt)
        vvatan2(&ang, fi, fr, &cnt)
        vvsincos(&sn, &cs, ang, &cnt)
        var er = logAmp, ei = logAmp
        vDSP_vmulD(mag, 1, cs, 1, &er, 1, len)
        vDSP_vmulD(mag, 1, sn, 1, &ei, 1, len)
        return (er, ei)
    }

    /// Squared magnitude, smoothed, min-shifted and scaled to a 0...1 peak; nil when the map is flat.
    private static func normalizedPower(_ ir: [Double], _ ii: [Double], width: Int, height: Int, kernel: [Double]) -> [Double]? {
        let n = ir.count, len = vDSP_Length(n)
        var re = ir, im = ii, sal = ir
        re.withUnsafeMutableBufferPointer { rp in
        im.withUnsafeMutableBufferPointer { ip in
            var z = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            vDSP_zvmagsD(&z, 1, &sal, 1, len)
        } }
        sal = filter(sal, width: width, height: height, kernel: kernel)
        var lo = 0.0, hi = 0.0
        vDSP_minvD(sal, 1, &lo, len)
        vDSP_maxvD(sal, 1, &hi, len)
        var neg = -lo, peak = hi - lo
        if peak <= 1e-8 { return nil }
        var shifted = sal
        vDSP_vsaddD(sal, 1, &neg, &shifted, 1, len)
        vDSP_vsdivD(shifted, 1, &peak, &sal, 1, len)
        return sal
    }

    private static func edgeSum(_ sal: [Double], _ w: Int, _ h: Int, _ border: Int) -> (edge: Double, total: Double) {
        var edge = 0.0, total = 0.0, part = 0.0
        vDSP_sveD(sal, 1, &total, vDSP_Length(sal.count))
        let left = min(border, w), rightStart = max(w - border, left)
        sal.withUnsafeBufferPointer { p in
            for y in 0..<h {
                let row = p.baseAddress! + y * w
                if y < border || y >= h - border {
                    vDSP_sveD(row, 1, &part, vDSP_Length(w)); edge += part
                } else {
                    vDSP_sveD(row, 1, &part, vDSP_Length(left)); edge += part
                    vDSP_sveD(row + rightStart, 1, &part, vDSP_Length(w - rightStart)); edge += part
                }
            }
        }
        return (edge, total)
    }

    private static func threshold(_ sal: [Double], _ cutoff: Double) -> [Bool] {
        sal.map { $0 >= cutoff }
    }

    // MARK: subject

    public static func subject(_ image: RGBImage, maxSide: Int) -> (SubjectRecord?, Double) {
        let (resized, _) = Resize.forAnalysis(image, maxSide: maxSide)
        let w = resized.width, h = resized.height, n = w * h
        let gray = grayscale(resized.pixels, n)
        if stddev(gray) < 1e-4 { return (nil, 0.0) }

        let (fr, fi) = dft2(gray, [Double](repeating: 0, count: n), width: w, height: h, inverse: false)
        let logAmp = logAmplitude(fr, fi)
        let smooth = filter(logAmp, width: w, height: h, kernel: [1.0 / 3, 1.0 / 3, 1.0 / 3])
        let (er, ei) = residual(logAmp, smooth, fr, fi)
        let (ir, ii) = dft2(er, ei, width: w, height: h, inverse: true)
        var kern = [Double](repeating: 0, count: 9)
        for k in 0..<9 {
            let d = Double(k - 4)
            kern[k] = exp(-(d * d) / 12.5)
        }
        let ksum = kern.reduce(0, +)
        kern = kern.map { $0 / ksum }
        guard let sal = normalizedPower(ir, ii, width: w, height: h, kernel: kern) else { return (nil, 0.0) }

        let border = max(1, Int((Double(min(w, h)) * 0.04).rounded(.toNearestOrEven)))
        let sums = edgeSum(sal, w, h, border)
        let edgeEnergy = sums.edge / max(sums.total, 1e-8)
        let edgeRisk = min(max(edgeEnergy / 0.22, 0), 1)

        let cutoff = max(0.35, quantile(sal, 0.82))
        let mask = threshold(sal, cutoff)
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
