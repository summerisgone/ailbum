import Foundation
import CoreML

public enum FaceAlign {
    static let template: [SIMD2<Double>] = [
        SIMD2(38.2946, 51.6963), SIMD2(73.5318, 51.5014), SIMD2(56.0252, 71.7366),
        SIMD2(41.5493, 92.3655), SIMD2(70.7299, 92.2041),
    ]
    static let size = 112

    /// Forward similarity transform (src -> template), as OpenCV's getSimilarityTransformMatrix:
    /// Umeyama without reflection. Returns [a, b, tx, c, d, ty] with x' = a x + b y + tx.
    static func similarity(_ src: [SIMD2<Float>]) -> [Double] {
        let s = src.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        let srcMean = s.reduce(SIMD2<Double>(0, 0), +) / 5
        let dstMean = SIMD2<Double>(56.0262, 71.9008)
        var a00 = 0.0, a01 = 0.0, a10 = 0.0, a11 = 0.0, v = 0.0
        for i in 0..<5 {
            let sd = s[i] - srcMean
            let dd = template[i] - dstMean
            a00 += dd.x * sd.x; a01 += dd.x * sd.y; a10 += dd.y * sd.x; a11 += dd.y * sd.y
            v += sd.x * sd.x + sd.y * sd.y
        }
        a00 /= 5; a01 /= 5; a10 /= 5; a11 /= 5; v /= 5
        // best rotation maximises trace(R^T A); that maximum equals the signed singular-value sum
        let p = a00 + a11, q = a10 - a01
        let m = (p * p + q * q).squareRoot()
        guard m > 0, v > 0 else { return [1, 0, 0, 0, 1, 0] }
        let c = p / m, sn = q / m
        let scale = m / v
        let a = scale * c, b = -scale * sn, cc = scale * sn, d = scale * c
        return [a, b, dstMean.x - (a * srcMean.x + b * srcMean.y),
                cc, d, dstMean.y - (cc * srcMean.x + d * srcMean.y)]
    }

    public static func alignCrop(_ image: RGBImage, landmarks: [SIMD2<Float>]) -> RGBImage {
        precondition(landmarks.count == 5, "alignCrop needs 5 landmarks")
        let t = similarity(landmarks)
        let det = t[0] * t[4] - t[1] * t[3]
        var out = [UInt8](repeating: 0, count: size * size * 3)
        guard det != 0 else { return RGBImage(width: size, height: size, pixels: out) }
        // invert the forward map; sample src for each destination pixel
        let ia = t[4] / det, ib = -t[1] / det, ic = -t[3] / det, id = t[0] / det
        let itx = -(ia * t[2] + ib * t[5]), ity = -(ic * t[2] + id * t[5])
        let w = image.width, h = image.height
        image.pixels.withUnsafeBufferPointer { src in
            for y in 0..<size {
                for x in 0..<size {
                    let fx = ia * Double(x) + ib * Double(y) + itx
                    let fy = ic * Double(x) + id * Double(y) + ity
                    let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
                    let wx = fx - Double(x0), wy = fy - Double(y0)
                    for ch in 0..<3 {
                        func px(_ xx: Int, _ yy: Int) -> Double {
                            (xx < 0 || yy < 0 || xx >= w || yy >= h) ? 0 : Double(src[(yy * w + xx) * 3 + ch])
                        }
                        let top = px(x0, y0) * (1 - wx) + px(x0 + 1, y0) * wx
                        let bot = px(x0, y0 + 1) * (1 - wx) + px(x0 + 1, y0 + 1) * wx
                        let val = (top * (1 - wy) + bot * wy).rounded()
                        out[(y * size + x) * 3 + ch] = UInt8(max(0, min(255, val)))
                    }
                }
            }
        }
        return RGBImage(width: size, height: size, pixels: out)
    }

    /// SFace embedding of a 112x112 aligned crop, L2-normalised (128 floats).
    public static func embed(_ aligned: RGBImage) throws -> [Float] {
        let input = Tensor.nchw(aligned, bgr: false, scale: 1, mean: [0, 0, 0])
        let outputs = try ModelStore.predict("sface", inputs: ["data": input])
        guard let raw = outputs["fc1"] ?? outputs.values.first else {
            throw AilbumError.decode("sface produced no output")
        }
        let norm = max(raw.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot(), 1e-8)
        return raw.map { Float(Double($0) / norm) }
    }
}
