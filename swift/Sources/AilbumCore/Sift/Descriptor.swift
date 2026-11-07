import Foundation

public enum SiftDescriptor {
    static let d = 4
    static let n = 8

    public static func compute(_ kps: [SiftKeypoint], space: ScaleSpace) -> [Float] {
        let count = kps.count
        var out = [Float](repeating: 0, count: count * 128)
        if count == 0 { return out }
        out.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: count) { i in
                let dst = UnsafeMutableBufferPointer(start: base + i * 128, count: 128)
                describe(kps[i], space: space, into: dst)
            }
        }
        return out
    }

    private static func describe(_ kp: SiftKeypoint, space: ScaleSpace, into dst: UnsafeMutableBufferPointer<Float>) {
        let o = kp.octave - space.firstOctave
        guard o >= 0, o < space.gaussians.count, kp.layer >= 0, kp.layer < space.gaussians[o].count else { return }
        let img = space.gaussians[o][kp.layer]
        let rows = img.height, cols = img.width
        let scale = Float(pow(2.0, Double(-kp.octave)))
        let ptx = Int((kp.x * scale).rounded()), pty = Int((kp.y * scale).rounded())
        let scl = kp.size * 0.5 * scale
        let ori = kp.angle < 0 ? 0 : kp.angle
        let d = Self.d, n = Self.n

        let cosT = Float(cos(Double(ori) * .pi / 180))
        let sinT = Float(sin(Double(ori) * .pi / 180))
        let histWidth: Float = 3 * scl
        let cosH = cosT / histWidth, sinH = sinT / histWidth
        let binsPerRad = Float(n) / 360
        let expScale: Float = -1 / (Float(d * d) * 0.5)
        let rf: Float = histWidth * Float(2.0).squareRoot() * Float(d + 1) * 0.5
        let diag = Int(Float(rows * rows + cols * cols).squareRoot())
        let radius: Int = min(Int(rf.rounded()), diag)

        var hist = [Float](repeating: 0, count: (d + 2) * (d + 2) * (n + 2))
        img.pixels.withUnsafeBufferPointer { p in
            for i in -radius...radius {
                for j in -radius...radius {
                    let cRot = Float(j) * cosH - Float(i) * sinH
                    let rRot = Float(j) * sinH + Float(i) * cosH
                    var rbin = rRot + Float(d) / 2 - 0.5
                    var cbin = cRot + Float(d) / 2 - 0.5
                    let r = pty + i, c = ptx + j
                    guard rbin > -1, rbin < Float(d), cbin > -1, cbin < Float(d),
                          r > 0, r < rows - 1, c > 0, c < cols - 1 else { continue }
                    let dx = p[r * cols + c + 1] - p[r * cols + c - 1]
                    let dy = p[(r - 1) * cols + c] - p[(r + 1) * cols + c]
                    let w = exp((cRot * cRot + rRot * rRot) * expScale)
                    var gradAng = atan2(dy, dx) * 180 / .pi
                    if gradAng < 0 { gradAng += 360 }
                    let mag = (dx * dx + dy * dy).squareRoot() * w
                    var obin = (gradAng - ori) * binsPerRad

                    let r0 = Int(rbin.rounded(.down)), c0 = Int(cbin.rounded(.down)); var o0 = Int(obin.rounded(.down))
                    rbin -= Float(r0); cbin -= Float(c0); obin -= Float(o0)
                    if o0 < 0 { o0 += n }
                    if o0 >= n { o0 -= n }

                    let v_r1 = mag * rbin, v_r0 = mag - v_r1
                    let v_rc11 = v_r1 * cbin, v_rc10 = v_r1 - v_rc11
                    let v_rc01 = v_r0 * cbin, v_rc00 = v_r0 - v_rc01
                    let v_rco111 = v_rc11 * obin, v_rco110 = v_rc11 - v_rco111
                    let v_rco101 = v_rc10 * obin, v_rco100 = v_rc10 - v_rco101
                    let v_rco011 = v_rc01 * obin, v_rco010 = v_rc01 - v_rco011
                    let v_rco001 = v_rc00 * obin, v_rco000 = v_rc00 - v_rco001

                    let idx = ((r0 + 1) * (d + 2) + c0 + 1) * (n + 2) + o0
                    hist[idx] += v_rco000
                    hist[idx + 1] += v_rco001
                    hist[idx + (n + 2)] += v_rco010
                    hist[idx + (n + 3)] += v_rco011
                    hist[idx + (d + 2) * (n + 2)] += v_rco100
                    hist[idx + (d + 2) * (n + 2) + 1] += v_rco101
                    hist[idx + (d + 3) * (n + 2)] += v_rco110
                    hist[idx + (d + 3) * (n + 2) + 1] += v_rco111
                }
            }
        }

        for i in 0..<d {
            for j in 0..<d {
                let idx = ((i + 1) * (d + 2) + j + 1) * (n + 2)
                hist[idx] += hist[idx + n]
                hist[idx + 1] += hist[idx + n + 1]
                for k in 0..<n { dst[(i * d + j) * n + k] = hist[idx + k] }
            }
        }

        var nrm2: Float = 0
        for k in 0..<128 { nrm2 += dst[k] * dst[k] }
        let thr = nrm2.squareRoot() * 0.2
        nrm2 = 0
        for k in 0..<128 {
            let v = min(dst[k], thr)
            dst[k] = v
            nrm2 += v * v
        }
        let nrm = 512 / max(nrm2.squareRoot(), Float.ulpOfOne)
        for k in 0..<128 {
            dst[k] = min(max((dst[k] * nrm).rounded(.toNearestOrEven), 0), 255)
        }
    }
}
