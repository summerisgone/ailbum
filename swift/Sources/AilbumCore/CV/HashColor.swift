import Foundation

public enum HashColor {
    private static let dctMatrix: [Double] = {
        let n = 32
        var m = [Double](repeating: 0, count: n * n)
        for k in 0..<n {
            let scale = k == 0 ? (1.0 / Double(n)).squareRoot() : (2.0 / Double(n)).squareRoot()
            for i in 0..<n {
                m[k * n + i] = scale * cos(Double.pi * (2 * Double(i) + 1) * Double(k) / (2 * Double(n)))
            }
        }
        return m
    }()

    // OpenCV 8-bit fixed-point tables (hsv_shift = 12)
    static let sdiv: [Int32] = (0..<256).map { $0 == 0 ? 0 : Int32(((255.0 * 4096.0) / Double($0)).rounded(.toNearestOrEven)) }
    static let hdiv: [Int32] = (0..<256).map { $0 == 0 ? 0 : Int32(((180.0 * 4096.0) / (6.0 * Double($0))).rounded(.toNearestOrEven)) }

    public static func features(_ image: RGBImage) -> (phash: [Bool], histogram: [Float]) {
        let small = image.width == 32 && image.height == 32 ? image : Resize.area(image, width: 32, height: 32)
        let large = image.width == 256 && image.height == 256 ? image : Resize.area(image, width: 256, height: 256)
        return (phash(small), histogram(large))
    }

    private static func phash(_ img: RGBImage) -> [Bool] {
        let n = 32
        var gray = [Double](repeating: 0, count: n * n)
        for i in 0..<(n * n) {
            let r = Int32(img.pixels[i * 3]), g = Int32(img.pixels[i * 3 + 1]), b = Int32(img.pixels[i * 3 + 2])
            gray[i] = Double((r * 4899 + g * 9617 + b * 1868 + 8192) >> 14)
        }
        let m = dctMatrix
        // tmp = gray * M^T (rows), out = M * tmp (columns); only top-left 8x8 needed
        var tmp = [Double](repeating: 0, count: n * 8)
        for y in 0..<n {
            for u in 0..<8 {
                var s = 0.0
                for x in 0..<n { s += gray[y * n + x] * m[u * n + x] }
                tmp[y * 8 + u] = s
            }
        }
        var values = [Double](repeating: 0, count: 64)
        for v in 0..<8 {
            for u in 0..<8 {
                var s = 0.0
                for y in 0..<n { s += m[v * n + y] * tmp[y * 8 + u] }
                // cv2 yields exact zeros for symmetric inputs; snap float noise so the median matches
                values[v * 8 + u] = abs(s) < 1e-6 ? 0 : s
            }
        }
        let median = values[1...].sorted()[31]
        return values.map { $0 > median }
    }

    private static func histogram(_ img: RGBImage) -> [Float] {
        var hist = [Float](repeating: 0, count: 24 * 16)
        for i in 0..<(img.width * img.height) {
            let r = Int32(img.pixels[i * 3]), g = Int32(img.pixels[i * 3 + 1]), b = Int32(img.pixels[i * 3 + 2])
            let v = max(r, g, b)
            let diff = v - min(r, g, b)
            let s = (diff * sdiv[Int(v)] + (1 << 11)) >> 12
            let vr: Int32 = v == r ? -1 : 0
            let vg: Int32 = v == g ? -1 : 0
            var h = (vr & (g - b)) + (~vr & ((vg & (b - r + 2 * diff)) + (~vg & (r - g + 4 * diff))))
            h = (h * hdiv[Int(diff)] + (1 << 11)) >> 12
            if h < 0 { h += 180 }
            hist[Int(h) * 24 / 180 * 16 + Int(s) / 16] += 1
        }
        var sum: Float = 0
        for x in hist { sum += x * x }
        let norm = max(sum.squareRoot(), 1e-8)
        return hist.map { $0 / norm }
    }

    public static func hamming(_ a: [Bool], _ b: [Bool]) -> Int {
        zip(a, b).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
    }

    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
