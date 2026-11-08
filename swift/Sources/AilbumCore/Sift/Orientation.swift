import Foundation

extension SiftDetector {
    static let orientationBins = 36

    /// OpenCV `calcOrientationHist` + peak extraction; one output keypoint per qualifying peak.
    public static func assignOrientations(_ kps: [SiftKeypoint], space: ScaleSpace) -> [SiftKeypoint] {
        var out: [SiftKeypoint] = []
        let n = orientationBins
        for kp in kps {
            let o = kp.octave - space.firstOctave
            guard o >= 0, o < space.gaussians.count, kp.layer >= 0, kp.layer < space.gaussians[o].count else { continue }
            let img = space.gaussians[o][kp.layer]
            let scale = Float(pow(2.0, Double(-kp.octave)))
            let scl = kp.size * 0.5 * scale
            let cx = Int((kp.x * scale).rounded(.toNearestOrEven)), cy = Int((kp.y * scale).rounded(.toNearestOrEven))
            let radius = Int((3 * 1.5 * scl).rounded(.toNearestOrEven))
            let sigma = 1.5 * scl
            let expScale = -1 / (2 * sigma * sigma)

            var hist = [Float](repeating: 0, count: n)
            if radius >= 0 {
                for i in -radius...radius {
                    let y = cy + i
                    if y <= 0 || y >= img.height - 1 { continue }
                    for j in -radius...radius {
                        let x = cx + j
                        if x <= 0 || x >= img.width - 1 { continue }
                        let dx = img.pixels[y * img.width + x + 1] - img.pixels[y * img.width + x - 1]
                        let dy = img.pixels[(y - 1) * img.width + x] - img.pixels[(y + 1) * img.width + x]
                        let w = exp(Float(i * i + j * j) * expScale)
                        var ori = atan2(dy, dx) * 180 / .pi
                        if ori < 0 { ori += 360 }
                        var bin = Int((ori * Float(n) / 360).rounded(.toNearestOrEven))
                        if bin >= n { bin -= n }
                        if bin < 0 { bin += n }
                        hist[bin] += w * (dx * dx + dy * dy).squareRoot()
                    }
                }
            }

            var smooth = [Float](repeating: 0, count: n)
            for i in 0..<n {
                func h(_ k: Int) -> Float { hist[((k % n) + n) % n] }
                smooth[i] = (h(i - 2) + h(i + 2)) * (1.0 / 16) + (h(i - 1) + h(i + 1)) * (4.0 / 16) + h(i) * (6.0 / 16)
            }
            let maxVal = smooth.max() ?? 0
            let thr = 0.8 * maxVal
            for j in 0..<n {
                let l = j > 0 ? j - 1 : n - 1
                let r = j < n - 1 ? j + 1 : 0
                guard smooth[j] > smooth[l], smooth[j] > smooth[r], smooth[j] >= thr else { continue }
                var bin = Float(j) + 0.5 * (smooth[l] - smooth[r]) / (smooth[l] - 2 * smooth[j] + smooth[r])
                if bin < 0 { bin += Float(n) } else if bin >= Float(n) { bin -= Float(n) }
                var angle = 360 - (360 / Float(n)) * bin
                if abs(angle - 360) < Float.ulpOfOne { angle = 0 }
                var k = kp
                k.angle = angle
                out.append(k)
            }
        }
        return out
    }

    /// Removes exact duplicates, stable-sorts by response descending, keeps `maxFeatures` (0 keeps all).
    public static func retainBest(_ kps: [SiftKeypoint], maxFeatures: Int) -> [SiftKeypoint] {
        struct Key: Hashable { let x, y, size, angle: UInt32 }
        var seen = Set<Key>()
        var unique: [SiftKeypoint] = []
        for k in kps where seen.insert(Key(x: k.x.bitPattern, y: k.y.bitPattern, size: k.size.bitPattern, angle: k.angle.bitPattern)).inserted {
            unique.append(k)
        }
        let sorted = unique.enumerated().sorted {
            $0.element.response != $1.element.response ? $0.element.response > $1.element.response : $0.offset < $1.offset
        }.map(\.element)
        return maxFeatures > 0 && sorted.count > maxFeatures ? Array(sorted.prefix(maxFeatures)) : sorted
    }
}
