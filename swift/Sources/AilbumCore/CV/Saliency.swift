import Foundation

/// Spectral-residual saliency, port of `_subject_from_saliency` (src/ailbum/cv/aesthetics.py).
public enum Saliency {
    // MARK: FFT

    private static func fftPow2(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        var j = 0
        for i in 1..<max(n, 1) {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let ang = -2.0 * Double.pi / Double(len)
            for start in stride(from: 0, to: n, by: len) {
                for k in 0..<(len / 2) {
                    let wr = cos(ang * Double(k)), wi = sin(ang * Double(k))
                    let a = start + k, b = a + len / 2
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                }
            }
            len <<= 1
        }
    }

    /// Forward unnormalised DFT of one line; Bluestein chirp-z for non-power-of-two lengths.
    private static func fft1(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        if n <= 1 { return }
        if n & (n - 1) == 0 { fftPow2(&re, &im); return }
        var m = 1
        while m < 2 * n - 1 { m <<= 1 }
        var wr = [Double](repeating: 0, count: n), wi = wr
        for k in 0..<n {
            let ang = -Double.pi * Double((k * k) % (2 * n)) / Double(n)
            wr[k] = cos(ang); wi[k] = sin(ang)
        }
        var ar = [Double](repeating: 0, count: m), ai = ar
        var br = ar, bi = ar
        for k in 0..<n {
            ar[k] = re[k] * wr[k] - im[k] * wi[k]
            ai[k] = re[k] * wi[k] + im[k] * wr[k]
        }
        br[0] = wr[0]; bi[0] = -wi[0]
        for k in 1..<n {
            br[k] = wr[k]; bi[k] = -wi[k]
            br[m - k] = wr[k]; bi[m - k] = -wi[k]
        }
        fftPow2(&ar, &ai); fftPow2(&br, &bi)
        for k in 0..<m {
            let r = ar[k] * br[k] - ai[k] * bi[k]
            let i = ar[k] * bi[k] + ai[k] * br[k]
            ar[k] = r; ai[k] = -i // conjugate for inverse via conj trick
        }
        fftPow2(&ar, &ai)
        let s = 1.0 / Double(m)
        for k in 0..<n {
            let cr = ar[k] * s, ci = -ai[k] * s
            re[k] = cr * wr[k] - ci * wi[k]
            im[k] = cr * wi[k] + ci * wr[k]
        }
    }

    /// 2-D DFT (numpy `fft2` / `ifft2`; the inverse is scaled by 1/(w*h)), row-major.
    public static func dft2(_ re: [Double], _ im: [Double], width: Int, height: Int, inverse: Bool) -> ([Double], [Double]) {
        var outR = re, outI = inverse ? im.map { -$0 } : im
        for y in 0..<height {
            var r = Array(outR[(y * width)..<((y + 1) * width)])
            var i = Array(outI[(y * width)..<((y + 1) * width)])
            fft1(&r, &i)
            for x in 0..<width { outR[y * width + x] = r[x]; outI[y * width + x] = i[x] }
        }
        for x in 0..<width {
            var r = (0..<height).map { outR[$0 * width + x] }
            var i = (0..<height).map { outI[$0 * width + x] }
            fft1(&r, &i)
            for y in 0..<height { outR[y * width + x] = r[y]; outI[y * width + x] = i[y] }
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
    private static func filter(_ src: [Double], width: Int, height: Int, kernel: [Double]) -> [Double] {
        let r = kernel.count / 2
        var tmp = src
        for y in 0..<height { for x in 0..<width {
            var a = 0.0
            for k in 0..<kernel.count { a += kernel[k] * src[y * width + reflect101(x + k - r, width)] }
            tmp[y * width + x] = a
        } }
        var out = tmp
        for y in 0..<height { for x in 0..<width {
            var a = 0.0
            for k in 0..<kernel.count { a += kernel[k] * tmp[reflect101(y + k - r, height) * width + x] }
            out[y * width + x] = a
        } }
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
