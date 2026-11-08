import Foundation

public enum YOLOX {
    static let inputSize = 640
    static let padValue: UInt8 = 114
    static let strides = [8, 16, 32]
    static let scoreThreshold: Float = 0.35
    static let nmsThreshold: Float = 0.5
    static let anchorCount = strides.reduce(0) { $0 + (inputSize / $1) * (inputSize / $1) }
    static let stride = 85

    static let labels = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
        "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
        "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
        "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
        "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
        "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
        "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
        "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse",
        "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
        "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier",
        "toothbrush",
    ]

    /// Per-anchor (gridX, gridY, stride) in output row order.
    static let anchors: [(Float, Float, Float)] = {
        var a: [(Float, Float, Float)] = []
        a.reserveCapacity(anchorCount)
        for s in strides {
            let n = inputSize / s
            for y in 0..<n { for x in 0..<n { a.append((Float(x), Float(y), Float(s))) } }
        }
        return a
    }()

    /// Resize into the top-left of a 640x640 canvas (bilinear, pad 114); returns the canvas and scale.
    public static func letterbox(_ image: RGBImage) -> (canvas: RGBImage, scale: Float) {
        let size = Double(inputSize)
        let scale = min(size / Double(image.height), size / Double(image.width))
        // Python round() is half-to-even
        let newW = max(1, min(inputSize, Int((Double(image.width) * scale).rounded(.toNearestOrEven))))
        let newH = max(1, min(inputSize, Int((Double(image.height) * scale).rounded(.toNearestOrEven))))
        var canvas = [UInt8](repeating: padValue, count: inputSize * inputSize * 3)
        let sx = Double(image.width) / Double(newW), sy = Double(image.height) / Double(newH)
        var x0s = [Int](repeating: 0, count: newW), x1s = x0s
        var fxs = [Float](repeating: 0, count: newW)
        for x in 0..<newW {
            let f = max(0, (Double(x) + 0.5) * sx - 0.5)
            let i = min(Int(f), image.width - 1)
            x0s[x] = i; x1s[x] = min(i + 1, image.width - 1); fxs[x] = Float(f - Double(i))
        }
        image.pixels.withUnsafeBufferPointer { src in
            for y in 0..<newH {
                let f = max(0, (Double(y) + 0.5) * sy - 0.5)
                let j0 = min(Int(f), image.height - 1), j1 = min(j0 + 1, image.height - 1)
                let fy = Float(f - Double(j0))
                for x in 0..<newW {
                    let fx = fxs[x]
                    for c in 0..<3 {
                        let p00 = Float(src[(j0 * image.width + x0s[x]) * 3 + c])
                        let p01 = Float(src[(j0 * image.width + x1s[x]) * 3 + c])
                        let p10 = Float(src[(j1 * image.width + x0s[x]) * 3 + c])
                        let p11 = Float(src[(j1 * image.width + x1s[x]) * 3 + c])
                        let top = p00 + (p01 - p00) * fx
                        let bottom = p10 + (p11 - p10) * fx
                        canvas[(y * inputSize + x) * 3 + c] = UInt8(max(0, min(255, (top + (bottom - top) * fy).rounded())))
                    }
                }
            }
        }
        return (RGBImage(width: inputSize, height: inputSize, pixels: canvas), Float(scale))
    }

    /// Decode a flat `(8400, 85)` output into boxes normalized to the original image.
    public static func decode(_ output: [Float], scale: Float, width: Int, height: Int) -> [DetectedObject] {
        guard output.count == anchorCount * stride, width > 0, height > 0 else { return [] }
        let w = Float(width), h = Float(height)
        var boxes: [SIMD4<Float>] = []   // x, y, w, h in original pixels
        var scores: [Float] = []
        var classes: [Int] = []
        for i in 0..<anchorCount {
            let b = i * stride
            let obj = output[b + 4]
            var best: Float = -.infinity
            var cls = 0
            for c in 0..<(stride - 5) {
                let s = obj * output[b + 5 + c]
                if s > best { best = s; cls = c }
            }
            guard best >= scoreThreshold else { continue }
            let (gx, gy, st) = anchors[i]
            let cx = (output[b] + gx) * st, cy = (output[b + 1] + gy) * st
            let sw = Float(exp(Double(min(max(output[b + 2], -20), 10)))) * st
            let sh = Float(exp(Double(min(max(output[b + 3], -20), 10)))) * st
            let x0 = min(max((cx - sw / 2) / scale, 0), w), y0 = min(max((cy - sh / 2) / scale, 0), h)
            let x1 = min(max((cx + sw / 2) / scale, 0), w), y1 = min(max((cy + sh / 2) / scale, 0), h)
            guard x1 - x0 > 0, y1 - y0 > 0 else { continue }
            boxes.append(SIMD4(x0, y0, x1 - x0, y1 - y0))
            scores.append(best); classes.append(cls)
        }
        let order = scores.indices.sorted { scores[$0] > scores[$1] || (scores[$0] == scores[$1] && $0 < $1) }
        var kept: [Int] = []
        for i in order {
            var keep = true
            for k in kept where classes[k] == classes[i] && iou(boxes[i], boxes[k]) > nmsThreshold {
                keep = false; break
            }
            if keep { kept.append(i) }
        }
        var results = kept.map { i -> DetectedObject in
            let b = boxes[i]
            return DetectedObject(label: labels[classes[i]], score: scores[i],
                                  bbox: SIMD4(b.x / w, b.y / h, b.z / w, b.w / h))
        }
        results.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return ($0.bbox.x, $0.bbox.y, $0.bbox.z, $0.bbox.w) < ($1.bbox.x, $1.bbox.y, $1.bbox.z, $1.bbox.w)
        }
        return results
    }

    private static func iou(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        let iw = min(a.x + a.z, b.x + b.z) - max(a.x, b.x)
        let ih = min(a.y + a.w, b.y + b.w) - max(a.y, b.y)
        guard iw > 0, ih > 0 else { return 0 }
        let inter = iw * ih
        return inter / (a.z * a.w + b.z * b.w - inter)
    }

    public static func detect(_ image: RGBImage) throws -> [DetectedObject] {
        guard image.width > 0, image.height > 0 else { return [] }
        let (canvas, scale) = letterbox(image)
        let input = Tensor.nchw(canvas, bgr: false, scale: 1, mean: [0, 0, 0])
        let outputs = try ModelStore.predict("yolox", inputs: ["images": input])
        guard let out = outputs["output"] ?? outputs.values.first else { return [] }
        return decode(out, scale: scale, width: image.width, height: image.height)
    }
}
