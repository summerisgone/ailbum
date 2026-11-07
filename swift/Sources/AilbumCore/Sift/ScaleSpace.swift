import Foundation
import Metal

extension ScaleSpace {
    public static func grayFloat(_ image: RGBImage) -> GrayImage {
        let n = image.width * image.height
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let r = Int(image.pixels[i * 3]), g = Int(image.pixels[i * 3 + 1]), b = Int(image.pixels[i * 3 + 2])
            out[i] = Float((r * 4899 + g * 9617 + b * 1868 + 8192) >> 14)
        }
        return GrayImage(width: image.width, height: image.height, pixels: out)
    }

    /// OpenCV getGaussianKernel for ksize > 7 (computed in double, normalised).
    private static func kernel(sigma: Double) -> [Float] {
        let ksize = Int((sigma * 8 + 1).rounded()) | 1
        let r = ksize / 2
        var w = (0..<ksize).map { exp(-Double(($0 - r) * ($0 - r)) / (2 * sigma * sigma)) }
        let s = w.reduce(0, +)
        w = w.map { $0 / s }
        return w.map { Float($0) }
    }

    public static func build(_ gray: GrayImage, layers: Int, sigma: Double) throws -> ScaleSpace {
        let ctx = MetalContext.shared
        guard let device = ctx.device, let queue = ctx.queue, let cb = queue.makeCommandBuffer() else {
            throw AilbumError.metal("no Metal device")
        }
        let up = try ctx.pipeline("sift_upsample2", source: SiftKernels.source)
        let blur = try ctx.pipeline("sift_blur1d", source: SiftKernels.source)
        let down = try ctx.pipeline("sift_downsample2", source: SiftKernels.source)
        let sub = try ctx.pipeline("sift_subtract", source: SiftKernels.source)

        func buf(_ n: Int) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: max(n, 1) * 4, options: .storageModeShared) else {
                throw AilbumError.metal("buffer allocation failed")
            }
            return b
        }
        func weightsBuffer(_ s: Double) throws -> (MTLBuffer, Int) {
            let k = kernel(sigma: s)
            guard let b = device.makeBuffer(bytes: k, length: k.count * 4, options: .storageModeShared) else {
                throw AilbumError.metal("buffer allocation failed")
            }
            return (b, k.count)
        }
        func dispatch(_ p: MTLComputePipelineState, _ w: Int, _ h: Int, _ set: (MTLComputeCommandEncoder) -> Void) {
            guard let e = cb.makeComputeCommandEncoder() else { return }
            e.setComputePipelineState(p)
            set(e)
            let tw = 16, th = 16
            e.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
            e.endEncoding()
        }
        func blurInto(_ src: MTLBuffer, _ dst: MTLBuffer, _ tmp: MTLBuffer, _ w: Int, _ h: Int, _ s: Double) throws {
            let (wb, ks) = try weightsBuffer(s)
            for (a, b, horiz) in [(src, tmp, 1), (tmp, dst, 0)] {
                var params = SIMD4<Int32>(Int32(w), Int32(h), Int32(ks), Int32(horiz))
                dispatch(blur, w, h) { e in
                    e.setBuffer(a, offset: 0, index: 0)
                    e.setBuffer(b, offset: 0, index: 1)
                    e.setBuffer(wb, offset: 0, index: 2)
                    e.setBytes(&params, length: 16, index: 3)
                }
            }
        }

        let firstOctave = -1
        let w0 = gray.width, h0 = gray.height
        let w2 = w0 * 2, h2 = h0 * 2
        let nOct = max(1, Int((log2(Double(max(1, min(w2, h2)))) - 2).rounded()) - firstOctave)

        var sig = [Double](repeating: 0, count: layers + 3)
        sig[0] = sigma
        let k = pow(2.0, 1.0 / Double(layers))
        for i in 1..<(layers + 3) {
            let prev = pow(k, Double(i - 1)) * sigma
            let total = prev * k
            sig[i] = (total * total - prev * prev).squareRoot()
        }

        guard w0 > 0, h0 > 0 else { throw AilbumError.decode("empty image") }
        let input = try buf(w0 * h0)
        gray.pixels.withUnsafeBytes { memcpy(input.contents(), $0.baseAddress!, w0 * h0 * 4) }
        let up2 = try buf(w2 * h2)
        var srcSize = SIMD2<Int32>(Int32(w0), Int32(h0))
        dispatch(up, w2, h2) { e in
            e.setBuffer(input, offset: 0, index: 0)
            e.setBuffer(up2, offset: 0, index: 1)
            e.setBytes(&srcSize, length: 8, index: 2)
        }

        var gBufs: [[MTLBuffer]] = []
        var dBufs: [[MTLBuffer]] = []
        var sizes: [(Int, Int)] = []
        var ow = w2, oh = h2
        var base = up2
        let sigDiff = max(sigma * sigma - 1.0, 0.01).squareRoot() // 0.5 initial sigma, doubled by upsample
        for o in 0..<nOct {
            sizes.append((ow, oh))
            let tmp = try buf(ow * oh)
            var level: [MTLBuffer] = []
            for i in 0..<(layers + 3) {
                let dst = try buf(ow * oh)
                if o == 0 && i == 0 {
                    try blurInto(base, dst, tmp, ow, oh, sigDiff)
                } else if i == 0 {
                    // base = every second pixel of previous octave's layer `layers`
                    var params = SIMD4<Int32>(Int32(sizes[o - 1].0), Int32(sizes[o - 1].1), Int32(ow), Int32(oh))
                    dispatch(down, ow, oh) { e in
                        e.setBuffer(base, offset: 0, index: 0)
                        e.setBuffer(dst, offset: 0, index: 1)
                        e.setBytes(&params, length: 16, index: 2)
                    }
                } else {
                    try blurInto(level[i - 1], dst, tmp, ow, oh, sig[i])
                }
                level.append(dst)
            }
            var dogs: [MTLBuffer] = []
            for i in 0..<(layers + 2) {
                let d = try buf(ow * oh)
                var n = Int32(ow * oh)
                dispatch(sub, ow * oh, 1) { e in
                    e.setBuffer(level[i + 1], offset: 0, index: 0)
                    e.setBuffer(level[i], offset: 0, index: 1)
                    e.setBuffer(d, offset: 0, index: 2)
                    e.setBytes(&n, length: 4, index: 3)
                }
                dogs.append(d)
            }
            gBufs.append(level)
            dBufs.append(dogs)
            base = level[layers]
            ow /= 2; oh /= 2
            if ow < 1 || oh < 1 { break }
        }
        cb.commit()
        cb.waitUntilCompleted()
        if cb.status != .completed { throw AilbumError.metal("command buffer failed: \(cb.status.rawValue)") }

        func read(_ b: MTLBuffer, _ w: Int, _ h: Int) -> GrayImage {
            let p = b.contents().bindMemory(to: Float.self, capacity: w * h)
            return GrayImage(width: w, height: h, pixels: Array(UnsafeBufferPointer(start: p, count: w * h)))
        }
        var gaussians: [[GrayImage]] = [], dogs: [[GrayImage]] = []
        for o in 0..<gBufs.count {
            let (w, h) = sizes[o]
            gaussians.append(gBufs[o].map { read($0, w, h) })
            dogs.append(dBufs[o].map { read($0, w, h) })
        }
        return ScaleSpace(firstOctave: firstOctave, layers: layers, sigma: sigma, gaussians: gaussians, dogs: dogs)
    }
}
