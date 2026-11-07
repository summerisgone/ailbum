import Foundation

public enum YuNet {
    static let inputSize = 640

    public static func decode(
        _ outputs: [String: [Float]], inputSize: Int, scale: Float,
        scoreThreshold: Float, nmsThreshold: Float, topK: Int
    ) -> [FaceDetection] {
        struct Candidate { var score: Float; var x: Float; var y: Float; var w: Float; var h: Float; var kps: [SIMD2<Float>] }
        var found: [Candidate] = []
        for s in [8, 16, 32] {
            guard let cls = outputs["cls_\(s)"], let obj = outputs["obj_\(s)"],
                  let bbox = outputs["bbox_\(s)"], let kps = outputs["kps_\(s)"] else { continue }
            let g = inputSize / s
            let fs = Float(s)
            guard cls.count >= g * g, obj.count >= g * g, bbox.count >= g * g * 4, kps.count >= g * g * 10 else { continue }
            for row in 0..<g {
                for col in 0..<g {
                    let i = row * g + col
                    let score = (min(max(cls[i], 0), 1) * min(max(obj[i], 0), 1)).squareRoot()
                    if score < scoreThreshold { continue }
                    let cx = (Float(col) + bbox[i * 4]) * fs
                    let cy = (Float(row) + bbox[i * 4 + 1]) * fs
                    let w = exp(bbox[i * 4 + 2]) * fs
                    let h = exp(bbox[i * 4 + 3]) * fs
                    let points = (0..<5).map { k in
                        SIMD2<Float>((kps[i * 10 + 2 * k] + Float(col)) * fs, (kps[i * 10 + 2 * k + 1] + Float(row)) * fs)
                    }
                    found.append(Candidate(score: score, x: cx - w / 2, y: cy - h / 2, w: w, h: h, kps: points))
                }
            }
        }
        found.sort { $0.score > $1.score }
        if found.count > topK { found.removeLast(found.count - topK) }
        var kept: [Candidate] = []
        for c in found {
            let suppressed = kept.contains { k in
                let iw = min(c.x + c.w, k.x + k.w) - max(c.x, k.x)
                let ih = min(c.y + c.h, k.y + k.h) - max(c.y, k.y)
                guard iw > 0, ih > 0 else { return false }
                let inter = iw * ih
                return inter / (c.w * c.h + k.w * k.h - inter) > nmsThreshold
            }
            if !suppressed { kept.append(c) }
        }
        func r(_ v: Float) -> Int { Int((v / scale).rounded(.toNearestOrEven)) }
        return kept.map { c in
            FaceDetection(
                bbox: (x: r(c.x), y: r(c.y), w: r(c.w), h: r(c.h)),
                confidence: c.score,
                landmarks: c.kps.map { $0 / scale })
        }
    }

    /// Clip to the image and drop small faces, as `_detect_dnn`.
    static func finalize(_ faces: [FaceDetection], width: Int, height: Int, minFaceSize: Int) -> [FaceDetection] {
        faces.compactMap { f in
            let x = max(0, f.bbox.x), y = max(0, f.bbox.y)
            let w = min(f.bbox.w, width - x), h = min(f.bbox.h, height - y)
            guard min(w, h) >= minFaceSize else { return nil }
            return FaceDetection(bbox: (x: x, y: y, w: w, h: h), confidence: f.confidence, landmarks: f.landmarks)
        }
    }

    public static func detect(_ image: RGBImage, minFaceSize: Int) throws -> [FaceDetection] {
        let n = inputSize
        let scale = Float(n) / Float(max(image.width, image.height))
        let nw = max(1, min(n, Int((Float(image.width) * scale).rounded())))
        let nh = max(1, min(n, Int((Float(image.height) * scale).rounded())))
        // Bilinear resize (half-pixel centres) into the top-left of a zero canvas.
        var canvas = RGBImage(width: n, height: n, pixels: [UInt8](repeating: 0, count: n * n * 3))
        let sx = Float(image.width) / Float(nw), sy = Float(image.height) / Float(nh)
        for y in 0..<nh {
            let fy = min(max((Float(y) + 0.5) * sy - 0.5, 0), Float(image.height - 1))
            let y0 = Int(fy), y1 = min(y0 + 1, image.height - 1), wy = fy - Float(y0)
            for x in 0..<nw {
                let fx = min(max((Float(x) + 0.5) * sx - 0.5, 0), Float(image.width - 1))
                let x0 = Int(fx), x1 = min(x0 + 1, image.width - 1), wx = fx - Float(x0)
                for c in 0..<3 {
                    let p00 = Float(image.pixels[(y0 * image.width + x0) * 3 + c])
                    let p01 = Float(image.pixels[(y0 * image.width + x1) * 3 + c])
                    let p10 = Float(image.pixels[(y1 * image.width + x0) * 3 + c])
                    let p11 = Float(image.pixels[(y1 * image.width + x1) * 3 + c])
                    let v = (p00 * (1 - wx) + p01 * wx) * (1 - wy) + (p10 * (1 - wx) + p11 * wx) * wy
                    canvas.pixels[(y * n + x) * 3 + c] = UInt8(min(max(v.rounded(), 0), 255))
                }
            }
        }
        let input = Tensor.nchw(canvas, bgr: true, scale: 1, mean: [0, 0, 0])
        let outputs = try ModelStore.predict("yunet", inputs: ["input": input])
        let faces = decode(outputs, inputSize: n, scale: scale, scoreThreshold: 0.75, nmsThreshold: 0.3, topK: 5000)
        return finalize(faces, width: image.width, height: image.height, minFaceSize: minFaceSize)
    }
}
