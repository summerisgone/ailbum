import Foundation
import Metal

public enum Matcher {
    /// Mutual knn(k=2) ratio matches, L2 distance, sorted by left index.
    public static func mutualRatioMatches(left: [Float], right: [Float], dim: Int, ratio: Float) throws -> [(Int, Int)] {
        guard dim > 0, dim <= 128, left.count % dim == 0, right.count % dim == 0 else {
            throw AilbumError.decode("invalid descriptor layout")
        }
        let nl = left.count / dim, nr = right.count / dim
        if nl < 2 || nr < 2 { return [] }
        let fwd = try knn2(query: left, train: right, dim: dim)
        let rev = try knn2(query: right, train: left, dim: dim)
        var out: [(Int, Int)] = []
        for i in 0..<nl {
            let (j, d1, d2) = fwd[i]
            guard j >= 0, d1.squareRoot() < ratio * d2.squareRoot() else { continue }
            let (back, e1, e2) = rev[j]
            if back == i, e1.squareRoot() < ratio * e2.squareRoot() { out.append((i, j)) }
        }
        return out
    }

    private static func knn2(query: [Float], train: [Float], dim: Int) throws -> [(Int, Float, Float)] {
        let ctx = MetalContext.shared
        guard let device = ctx.device, let queue = ctx.queue else { throw AilbumError.metal("no Metal device") }
        let nq = query.count / dim, nt = train.count / dim
        let pso = try ctx.pipeline("knn2", source: MatcherKernels.source)
        guard let qb = device.makeBuffer(bytes: query, length: query.count * 4, options: .storageModeShared),
              let tb = device.makeBuffer(bytes: train, length: train.count * 4, options: .storageModeShared),
              let ib = device.makeBuffer(length: nq * 4, options: .storageModeShared),
              let db = device.makeBuffer(length: nq * 8, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder()
        else { throw AilbumError.metal("buffer allocation failed") }
        var dims = SIMD3<Int32>(Int32(nq), Int32(nt), Int32(dim))
        enc.setComputePipelineState(pso)
        enc.setBuffer(qb, offset: 0, index: 0)
        enc.setBuffer(tb, offset: 0, index: 1)
        enc.setBuffer(ib, offset: 0, index: 2)
        enc.setBuffer(db, offset: 0, index: 3)
        enc.setBytes(&dims, length: MemoryLayout<SIMD3<Int32>>.size, index: 4)
        let tg = min(64, pso.maxTotalThreadsPerThreadgroup)
        enc.dispatchThreads(MTLSize(width: nq, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: tg, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let e = cmd.error { throw AilbumError.metal("\(e)") }
        let idx = ib.contents().bindMemory(to: Int32.self, capacity: nq)
        let dist = db.contents().bindMemory(to: Float.self, capacity: nq * 2)
        return (0..<nq).map { (Int(idx[$0]), dist[2 * $0], dist[2 * $0 + 1]) }
    }
}
