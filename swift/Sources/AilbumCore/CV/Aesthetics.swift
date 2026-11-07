import Foundation

public enum Aesthetics {
    private static func round4(_ v: Double) -> Double { (v * 10000).rounded(.toNearestOrEven) / 10000 }
    private static func clip(_ v: Double) -> Double { min(max(v, 0), 1) }

    public static func composition(_ image: RGBImage, faceBoxes: [SIMD4<Int>], maxSide: Int) -> CompositionRecord {
        var subject = subjectFromFaces(faceBoxes, width: image.width, height: image.height)
        var edgeEnergy = 0.0
        if subject == nil {
            (subject, edgeEnergy) = Saliency.subject(image, maxSide: maxSide)
        }
        guard let subject else {
            return CompositionRecord(ruleOfThirds: 0, frameOccupancy: 0, negativeSpace: 1, cropRisk: round4(edgeEnergy), score: 0, mainSubject: nil)
        }
        let (x, y, bw, bh) = (subject.bbox.x, subject.bbox.y, subject.bbox.z, subject.bbox.w)
        let occupancy = clip(bw * bh)
        let thirds = ruleOfThirds(subject.center)
        let margin = min(x, y, 1 - x - bw, 1 - y - bh)
        let boundaryRisk = clip((0.04 - margin) / 0.04)
        let cropRisk = max(boundaryRisk, edgeEnergy)
        let occupancyScore = clip(1 - abs(occupancy - 0.35) / 0.55)
        let score = 0.5 * thirds + 0.3 * (1 - cropRisk) + 0.2 * occupancyScore
        return CompositionRecord(
            ruleOfThirds: round4(thirds), frameOccupancy: round4(occupancy), negativeSpace: round4(1 - occupancy),
            cropRisk: round4(cropRisk), score: round4(score), mainSubject: subject)
    }

    public static func color(_ image: RGBImage, maxSide: Int) -> ColorRecord {
        let (resized, _) = Resize.forAnalysis(image, maxSide: maxSide)
        let width = resized.width, height = resized.height
        let n = width * height
        var hue = [Double](repeating: 0, count: n)
        var sat = [Double](repeating: 0, count: n)
        var weights = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let r = Int32(resized.pixels[i * 3]), g = Int32(resized.pixels[i * 3 + 1]), b = Int32(resized.pixels[i * 3 + 2])
            let v = max(r, g, b)
            let diff = v - min(r, g, b)
            let s = (diff * HashColor.sdiv[Int(v)] + (1 << 11)) >> 12
            let vr: Int32 = v == r ? -1 : 0
            let vg: Int32 = v == g ? -1 : 0
            var h = (vr & (g - b)) + (~vr & ((vg & (b - r + 2 * diff)) + (~vg & (r - g + 4 * diff))))
            h = (h * HashColor.hdiv[Int(diff)] + (1 << 11)) >> 12
            if h < 0 { h += 180 }
            hue[i] = Double(h)
            sat[i] = Double(s) / 255
            weights[i] = sat[i] * (0.25 + 0.75 * Double(v) / 255)
        }
        let total = weights.reduce(0, +)
        var balance = 1.0
        if total > 1e-6 {
            var cx = 0.0, cy = 0.0
            for yy in 0..<height {
                for xx in 0..<width {
                    let w = weights[yy * width + xx]
                    cx += w * (Double(xx) + 0.5) / Double(width)
                    cy += w * (Double(yy) + 0.5) / Double(height)
                }
            }
            let dx: Double = cx / total - 0.5
            let dy: Double = cy / total - 0.5
            let distance: Double = hypot(dx, dy) / Double(0.5).squareRoot()
            balance = clip(1 - distance)
        }
        return ColorRecord(
            balance: round4(balance), harmony: round4(hueHarmony(hue, sat)),
            meanSaturation: round4(sat.reduce(0, +) / Double(n)))
    }

    private static func subjectFromFaces(_ boxes: [SIMD4<Int>], width: Int, height: Int) -> SubjectRecord? {
        let valid = boxes.filter { $0.z > 0 && $0.w > 0 }
        guard !valid.isEmpty, width > 0, height > 0 else { return nil }
        let x1 = valid.map { $0.x }.min()!, y1 = valid.map { $0.y }.min()!
        let x2 = valid.map { $0.x + $0.z }.max()!, y2 = valid.map { $0.y + $0.w }.max()!
        let bbox = SIMD4(
            clip(Double(x1) / Double(width)), clip(Double(y1) / Double(height)),
            clip(Double(x2 - x1) / Double(width)), clip(Double(y2 - y1) / Double(height)))
        let center = SIMD2(bbox.x + bbox.z / 2, bbox.y + bbox.w / 2)
        return SubjectRecord(
            bbox: SIMD4(round4(bbox.x), round4(bbox.y), round4(bbox.z), round4(bbox.w)),
            center: SIMD2(round4(center.x), round4(center.y)), source: "faces")
    }

    private static func ruleOfThirds(_ center: SIMD2<Double>) -> Double {
        let a: Double = 1.0 / 3, b: Double = 2.0 / 3
        var d = Double.infinity
        for (px, py) in [(a, a), (b, a), (a, b), (b, b)] {
            d = min(d, hypot(center.x - px, center.y - py))
        }
        let z: Double = d / 0.22
        return exp(-0.5 * z * z)
    }

    private static func hueHarmony(_ hue: [Double], _ sat: [Double]) -> Double {
        var angles = [Double](), w = [Double](), histogram = [Double](repeating: 0, count: 36)
        for i in 0..<hue.count where sat[i] >= 0.12 {
            angles.append(hue[i] * 2)
            w.append(sat[i])
            histogram[min(Int(hue[i] / 5), 35)] += sat[i]
        }
        if angles.isEmpty { return 1 }
        var best = 0
        for i in 1..<36 where histogram[i] > histogram[best] { best = i }
        let dominant = (Double(best) + 0.5) * 5 * 2
        let schemes: [[Double]] = [
            [dominant],
            [dominant, (dominant + 180).truncatingRemainder(dividingBy: 360)],
            [dominant, (dominant + 120).truncatingRemainder(dividingBy: 360), (dominant + 240).truncatingRemainder(dividingBy: 360)],
        ]
        let weightSum = w.reduce(0, +)
        var bestScore = 0.0
        for scheme in schemes {
            var acc = 0.0
            for i in 0..<angles.count {
                var d = Double.infinity
                for t in scheme {
                    let diff = abs(angles[i] - t).truncatingRemainder(dividingBy: 360)
                    d = min(d, min(diff, 360 - diff))
                }
                let z: Double = d / 30
                acc += w[i] * exp(-0.5 * z * z)
            }
            bestScore = max(bestScore, acc / weightSum)
        }
        return clip(bestScore)
    }
}
