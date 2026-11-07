import CoreML

public enum Tensor {
    /// Float32 [1,3,H,W]; value = (pixel - mean[c]) * scale, c in model channel order.
    public static func nchw(_ image: RGBImage, bgr: Bool, scale: Float, mean: [Float]) -> MLMultiArray {
        let w = image.width, h = image.height
        let arr = try! MLMultiArray(shape: [1, 3, NSNumber(value: h), NSNumber(value: w)], dataType: .float32)
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * w * h)
        let plane = w * h
        image.pixels.withUnsafeBufferPointer { px in
            for c in 0..<3 {
                let src = bgr ? 2 - c : c
                let m = c < mean.count ? mean[c] : 0
                for i in 0..<plane {
                    ptr[c * plane + i] = (Float(px[i * 3 + src]) - m) * scale
                }
            }
        }
        return arr
    }
}
