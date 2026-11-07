import Foundation

public enum Vectors {
    public static func encode(_ v: [Float]) -> Data? {
        guard !v.isEmpty else { return nil }
        var data = Data(capacity: v.count * 4)
        for value in v {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func decode(_ d: Data, dimension: Int) -> [Float] {
        let embedding: [Float] = d.withUnsafeBytes { raw in
            (0..<dimension).map { index in
                Float(bitPattern: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self).littleEndian)
            }
        }
        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? embedding.map { $0 / norm } : embedding
    }

    public static func clusterCosine(_ features: [[Float]], threshold: Float) -> [[Int]] {
        guard !features.isEmpty else { return [] }
        let matrix: [[Float]] = features.map { row in
            let norm = sqrt(row.reduce(0) { $0 + $1 * $1 })
            let scale = max(norm, 1e-8)
            return row.map { $0 / scale }
        }
        let count = matrix.count
        var similarities = [[Float]](repeating: [Float](repeating: 0, count: count), count: count)
        for a in 0..<count {
            for b in 0..<count {
                similarities[a][b] = zip(matrix[a], matrix[b]).reduce(0) { $0 + $1.0 * $1.1 }
            }
        }
        var clusters: [[Int]] = (0..<count).map { [$0] }
        while true {
            var bestPair: (Int, Int)?
            var bestSimilarity = threshold
            for left in clusters.indices {
                for right in (left + 1)..<clusters.count {
                    var cross = Float.infinity
                    for a in clusters[left] {
                        for b in clusters[right] {
                            cross = min(cross, similarities[a][b])
                        }
                    }
                    if cross >= bestSimilarity {
                        bestPair = (left, right)
                        bestSimilarity = cross
                    }
                }
            }
            guard let best = bestPair else { break }
            let (left, right) = best
            let removed = clusters.remove(at: right)
            clusters[left] = (clusters[left] + removed).sorted()
        }
        return clusters.sorted { $0[0] < $1[0] }
    }
}

public struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    public init(size: Int) {
        parent = Array(0..<size)
        rank = Array(repeating: 0, count: size)
    }

    public mutating func find(_ item: Int) -> Int {
        var item = item
        while parent[item] != item {
            parent[item] = parent[parent[item]]
            item = parent[item]
        }
        return item
    }

    public mutating func union(_ left: Int, _ right: Int) {
        var leftRoot = find(left)
        var rightRoot = find(right)
        if leftRoot == rightRoot { return }
        if rank[leftRoot] < rank[rightRoot] {
            swap(&leftRoot, &rightRoot)
        }
        parent[rightRoot] = leftRoot
        if rank[leftRoot] == rank[rightRoot] {
            rank[leftRoot] += 1
        }
    }

    public mutating func components() -> [[Int]] {
        var groups: [Int: [Int]] = [:]
        for item in parent.indices {
            groups[find(item), default: []].append(item)
        }
        return groups.values.sorted { $0[0] < $1[0] }
    }
}
