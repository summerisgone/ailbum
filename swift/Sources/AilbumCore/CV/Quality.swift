import Accelerate
import Foundation
import Metal

public enum Quality {
    private static func fitted(_ image: RGBImage, _ maxSide: Int) -> RGBImage {
        max(image.width, image.height) > maxSide ? Resize.forAnalysis(image, maxSide: maxSide).0 : image
    }

    public static func sharpness(_ image: RGBImage, maxSide: Int) throws -> Double {
        let img = fitted(image, maxSide)
        let w = img.width, h = img.height
        let n = w * h
        var gray = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let r = Int(img.pixels[i * 3]), g = Int(img.pixels[i * 3 + 1]), b = Int(img.pixels[i * 3 + 2])
            gray[i] = Float((r * 4899 + g * 9617 + b * 1868 + 8192) >> 14)
        }
        let ctx = MetalContext.shared
        guard let device = ctx.device, let queue = ctx.queue else { throw AilbumError.metal("no Metal device") }
        let blurP = try ctx.pipeline("gaussian3")
        let lapP = try ctx.pipeline("laplacian")
        let bytes = n * MemoryLayout<Float>.stride
        guard let bufIn = device.makeBuffer(bytes: gray, length: bytes, options: .storageModeShared),
              let bufBlur = device.makeBuffer(length: bytes, options: .storageModeShared),
              let bufLap = device.makeBuffer(length: bytes, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { throw AilbumError.metal("buffer allocation failed") }
        var size = SIMD2<Int32>(Int32(w), Int32(h))
        let grid = MTLSize(width: w, height: h, depth: 1)
        func dispatch(_ p: MTLComputePipelineState, _ a: MTLBuffer, _ b: MTLBuffer) {
            enc.setComputePipelineState(p)
            enc.setBuffer(a, offset: 0, index: 0)
            enc.setBuffer(b, offset: 0, index: 1)
            enc.setBytes(&size, length: MemoryLayout<SIMD2<Int32>>.size, index: 2)
            let tw = min(p.threadExecutionWidth, w)
            let th = max(1, min(p.maxTotalThreadsPerThreadgroup / tw, 8, h))
            enc.dispatchThreads(grid, threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        }
        dispatch(blurP, bufIn, bufBlur)
        enc.memoryBarrier(scope: .buffers)
        dispatch(lapP, bufBlur, bufLap)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let e = cmd.error { throw AilbumError.metal("\(e)") }

        let lap = UnsafeBufferPointer(start: bufLap.contents().bindMemory(to: Float.self, capacity: n), count: n)
        var d = [Double](repeating: 0, count: n)
        vDSP_vspdp(lap.baseAddress!, 1, &d, 1, vDSP_Length(n))
        var mean = 0.0, meanSq = 0.0
        vDSP_meanvD(d, 1, &mean, vDSP_Length(n))
        vDSP_measqvD(d, 1, &meanSq, vDSP_Length(n))
        return max(0, meanSq - mean * mean)
    }

    // Integer pipeline of OpenCV's 8-bit RGB2Lab (L channel only): gamma LUT,
    // fixed-point Y, cube-root LUT, integer scaling to 0..255.
    private static let gammaTable: [Int] = (0..<256).map { i in
        let c = Double(i) / 255.0
        let g = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        return Int((255.0 * 8.0 * g).rounded(.toNearestOrEven))
    }

    private static let cbrtTable: [Int] = (0..<2048).map { i in
        let x = Double(i) / 2040.0
        let v = x < 0.008856 ? x * 7.787 + 16.0 / 116.0 : cbrt(x)
        return Int((32768.0 * v).rounded(.toNearestOrEven))
    }

    public static func exposure(_ image: RGBImage, maxSide: Int) -> Double {
        let img = fitted(image, maxSide)
        let n = img.width * img.height
        let cr = 871, cg = 2929, cb = 296 // round(c * 4096) for R, G, B
        let lScale = 296
        let lShift = -((16 * 255 * 32768 + 50) / 100)
        var clipped = 0
        var total = 0.0
        for i in 0..<n {
            let s = (gammaTable[Int(img.pixels[i * 3])] * cr + gammaTable[Int(img.pixels[i * 3 + 1])] * cg
                + gammaTable[Int(img.pixels[i * 3 + 2])] * cb + 2048) >> 12
            let fy = cbrtTable[min(s, 2047)]
            let l8 = min(255, max(0, (lScale * fy + lShift + 16384) >> 15))
            let lum = Float(l8) / 255.0
            if lum < 0.03 || lum > 0.97 { clipped += 1 }
            total += Double(lum)
        }
        let clippedFrac = Double(clipped) / Double(n)
        let meanPenalty = min(abs(total / Double(n) - 0.5) / 0.5, 1.0)
        return max(0.0, 1.0 - 0.7 * clippedFrac - 0.3 * meanPenalty)
    }

    public static func score(sharpness: Double, exposure: Double) -> Double {
        let comp = min(log1p(max(sharpness, 0.0)) / log1p(1000.0), 1.0)
        return 0.8 * comp + 0.2 * exposure
    }
}
