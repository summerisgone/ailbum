import Foundation

public struct RankingCandidate {
    public let imageId: Int
    public let score: Double
    public let storyId: Int?
    public let similarCluster: Int?
    public let embedding: [Double]?

    public init(imageId: Int, score: Double, storyId: Int?, similarCluster: Int?, embedding: [Double]?) {
        self.imageId = imageId
        self.score = score
        self.storyId = storyId
        self.similarCluster = similarCluster
        self.embedding = embedding
    }
}

public enum RankingSelect {
    private static func unit(_ vector: [Double]?) -> [Double]? {
        guard let vector else { return nil }
        let norm = vector.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : nil
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }

    /// Keep first, then greedily fill to target: score minus 0.5 x max cosine to taken, stories first, no repeated similar cluster.
    public static func selectForTarget(_ candidates: [RankingCandidate], target: Int, keep: [Int]) -> [Int] {
        var result = keep
        var byId: [Int: RankingCandidate] = [:]
        for c in candidates { byId[c.imageId] = c }
        let taken = keep.compactMap { byId[$0] }
        var stories = Set(taken.compactMap { $0.storyId })
        var clusters = Set(taken.compactMap { $0.similarCluster })
        var units = taken.compactMap { unit($0.embedding) }
        let keepSet = Set(keep)
        var remaining = candidates.filter { !keepSet.contains($0.imageId) }.sorted { $0.imageId < $1.imageId }

        func value(_ c: RankingCandidate) -> Double {
            var penalty = 0.0
            if let u = unit(c.embedding), !units.isEmpty {
                penalty = units.map { dot(u, $0) }.max() ?? 0
            }
            return c.score - 0.5 * penalty
        }

        while result.count < target && !remaining.isEmpty {
            let fresh = remaining.filter { $0.similarCluster == nil || !clusters.contains($0.similarCluster!) }
            let newStory = fresh.filter { $0.storyId == nil || !stories.contains($0.storyId!) }
            let pool = !newStory.isEmpty ? newStory : (!fresh.isEmpty ? fresh : remaining)
            var best = pool[0]
            var bestValue = value(best)
            for c in pool.dropFirst() {
                let v = value(c)
                if v > bestValue || (v == bestValue && c.imageId < best.imageId) {
                    best = c
                    bestValue = v
                }
            }
            if let i = remaining.firstIndex(where: { $0.imageId == best.imageId }) { remaining.remove(at: i) }
            result.append(best.imageId)
            if let s = best.storyId { stories.insert(s) }
            if let c = best.similarCluster { clusters.insert(c) }
            if let u = unit(best.embedding) { units.append(u) }
        }
        return result
    }
}
