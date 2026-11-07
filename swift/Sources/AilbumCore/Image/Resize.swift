import Foundation

public enum Resize {
    public static func forAnalysis(_ image: RGBImage, maxSide: Int) -> (RGBImage, Double) {
        let longest = max(image.width, image.height)
        let scale = min(1.0, Double(maxSide) / Double(longest))
        if scale >= 1.0 { return (image, 1.0) }
        let w = max(1, Int((Double(image.width) * scale).rounded(.toNearestOrEven)))
        let h = max(1, Int((Double(image.height) * scale).rounded(.toNearestOrEven)))
        return (area(image, width: w, height: h), scale)
    }

    /// OpenCV INTER_AREA: pixel-coverage weighted box average, rounded to UInt8.
    public static func area(_ image: RGBImage, width: Int, height: Int) -> RGBImage {
        if width == image.width && height == image.height { return image }
        let wx = weights(from: image.width, to: width)
        let wy = weights(from: image.height, to: height)
        // horizontal pass
        var tmp = [Float](repeating: 0, count: image.height * width * 3)
        for y in 0..<image.height {
            for ox in 0..<width {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for (sx, wgt) in wx[ox] {
                    let i = (y * image.width + sx) * 3
                    r += Float(image.pixels[i]) * wgt
                    g += Float(image.pixels[i + 1]) * wgt
                    b += Float(image.pixels[i + 2]) * wgt
                }
                let o = (y * width + ox) * 3
                tmp[o] = r; tmp[o + 1] = g; tmp[o + 2] = b
            }
        }
        var out = [UInt8](repeating: 0, count: width * height * 3)
        for oy in 0..<height {
            for x in 0..<width {
                var acc: [Float] = [0, 0, 0]
                for (sy, wgt) in wy[oy] {
                    let i = (sy * width + x) * 3
                    acc[0] += tmp[i] * wgt
                    acc[1] += tmp[i + 1] * wgt
                    acc[2] += tmp[i + 2] * wgt
                }
                let o = (oy * width + x) * 3
                for c in 0..<3 {
                    out[o + c] = UInt8(max(0, min(255, (acc[c] + 0.5).rounded(.down))))
                }
            }
        }
        return RGBImage(width: width, height: height, pixels: out)
    }

    private static func weights(from src: Int, to dst: Int) -> [[(Int, Float)]] {
        let scale = Double(src) / Double(dst)
        return (0..<dst).map { o in
            let start = Double(o) * scale
            let end = min(Double(src), start + scale)
            let first = Int(start.rounded(.down))
            let last = min(src - 1, Int(end.rounded(.up)) - 1)
            var list: [(Int, Float)] = []
            if first <= last {
                for s in first...last {
                    let cover = min(Double(s + 1), end) - max(Double(s), start)
                    if cover > 1e-9 { list.append((s, Float(cover / scale))) }
                }
            }
            return list
        }
    }
}
