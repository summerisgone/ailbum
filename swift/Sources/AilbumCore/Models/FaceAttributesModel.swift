import CoreML
import Foundation

public enum FaceAttributesModel {
    public static let expressionLabels = ["angry", "disgust", "fearful", "happy", "neutral", "sad", "surprised"]

    /// Model access seam so tests can swap a fake for the CoreML store.
    struct Backend {
        var available: (String) -> Bool
        var predict: (String, [String: MLMultiArray]) throws -> [String: [Float]]
        static let real = Backend(
            available: { ModelStore.available($0) },
            predict: { try ModelStore.predict($0, inputs: $1) })
    }

    public static func asProbabilities(_ values: [Float]) throws -> [Float] {
        if values.isEmpty { throw AilbumError.decode("Classifier returned an empty output") }
        let sum = values.reduce(0, +)
        if values.allSatisfy({ $0 >= 0 && $0 <= 1 }) && abs(sum - 1) <= 1e-3 { return values }
        let top = values.max()!
        let exps = values.map { Float(exp(Double($0 - top))) }
        let total = max(exps.reduce(0, +), 1e-8)
        return exps.map { $0 / total }
    }

    public static func classify(_ aligned: RGBImage) throws -> FaceAttributes {
        try classify(aligned, backend: .real)
    }

    static func classify(_ aligned: RGBImage, backend: Backend) throws -> FaceAttributes {
        var attributes = FaceAttributes()
        if backend.available("eye") {
            for (side, center) in [("right", (38, 52)), ("left", (74, 52))] {
                guard let patch = squareCrop(aligned, center: center, side: 16) else { continue }
                let input = Tensor.nchw(bilinear(patch, width: 32, height: 32),
                                        bgr: true, scale: 1.0 / 255.0, mean: [127, 127, 127])
                let out = try backend.predict("eye", ["input_1": input])
                let probabilities = try asProbabilities(out["var_19"] ?? [])
                let probability = round4(probabilities[0])
                let state = probability >= 0.5 ? "open" : "closed"
                if side == "left" {
                    attributes.leftEye = state
                    attributes.leftEyeOpenProbability = probability
                } else {
                    attributes.rightEye = state
                    attributes.rightEyeOpenProbability = probability
                }
            }
        }
        if backend.available("expression") {
            let face = Resize.area(aligned, width: 112, height: 112)
            let input = Tensor.nchw(face, bgr: false, scale: 1.0 / 127.5, mean: [127.5, 127.5, 127.5])
            let out = try backend.predict("expression", ["data": input])
            let probabilities = try asProbabilities(out["label"] ?? [])
            var scores: [String: Double] = [:]
            for (label, p) in zip(expressionLabels, probabilities) { scores[label] = round4(p) }
            // first maximum in label order, like Python max over the dict
            var best = expressionLabels[0]
            for label in expressionLabels where scores[label] != nil && scores[label]! > scores[best]! { best = label }
            attributes.expression = best
            attributes.expressionConfidence = scores[best]
            attributes.expressionScores = scores
        }
        return attributes
    }

    static func round4(_ value: Float) -> Double {
        (Double(value) * 10000).rounded(.toNearestOrEven) / 10000
    }

    /// Port of `_square_crop`: clipped window [x-half, x+half) x [y-half, y+half).
    static func squareCrop(_ image: RGBImage, center: (Int, Int), side: Int) -> RGBImage? {
        let half = side / 2
        let left = max(0, center.0 - half), top = max(0, center.1 - half)
        let right = min(image.width, center.0 + half), bottom = min(image.height, center.1 + half)
        guard right > left, bottom > top else { return nil }
        var pixels = [UInt8]()
        pixels.reserveCapacity((right - left) * (bottom - top) * 3)
        for y in top..<bottom {
            let start = (y * image.width + left) * 3
            pixels.append(contentsOf: image.pixels[start..<start + (right - left) * 3])
        }
        return RGBImage(width: right - left, height: bottom - top, pixels: pixels)
    }

    /// OpenCV INTER_LINEAR (half-pixel centres, edge clamp), rounded to UInt8.
    static func bilinear(_ image: RGBImage, width: Int, height: Int) -> RGBImage {
        if image.width == width && image.height == height { return image }
        var out = [UInt8](repeating: 0, count: width * height * 3)
        let sx = Float(image.width) / Float(width), sy = Float(image.height) / Float(height)
        for y in 0..<height {
            let fy = max(0, (Float(y) + 0.5) * sy - 0.5)
            let y0 = min(Int(fy), image.height - 1), y1 = min(y0 + 1, image.height - 1)
            let wy = fy - Float(y0)
            for x in 0..<width {
                let fx = max(0, (Float(x) + 0.5) * sx - 0.5)
                let x0 = min(Int(fx), image.width - 1), x1 = min(x0 + 1, image.width - 1)
                let wx = fx - Float(x0)
                for c in 0..<3 {
                    func px(_ xx: Int, _ yy: Int) -> Float { Float(image.pixels[(yy * image.width + xx) * 3 + c]) }
                    let top = px(x0, y0) * (1 - wx) + px(x1, y0) * wx
                    let bot = px(x0, y1) * (1 - wx) + px(x1, y1) * wx
                    out[(y * width + x) * 3 + c] = UInt8(max(0, min(255, (top * (1 - wy) + bot * wy).rounded())))
                }
            }
        }
        return RGBImage(width: width, height: height, pixels: out)
    }
}
