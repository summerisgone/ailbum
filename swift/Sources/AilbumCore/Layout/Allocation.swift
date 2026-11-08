import Foundation

public struct StoryGroup: Equatable, Sendable {
    public var storyIds: [Int]
    public var unitCount: Int
    public var startedAt: String?
    public var endedAt: String?

    public init(storyIds: [Int], unitCount: Int, startedAt: String?, endedAt: String?) {
        self.storyIds = storyIds
        self.unitCount = unitCount
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct Allocation: Equatable, Sendable {
    public var storyIds: [Int]
    public var unitCount: Int
    public var spreads: Int
    public var merged: Bool

    public init(storyIds: [Int], unitCount: Int, spreads: Int, merged: Bool) {
        self.storyIds = storyIds
        self.unitCount = unitCount
        self.spreads = spreads
        self.merged = merged
    }
}

public enum SpreadAllocation {
    static let missingUnitPenalty = 1000.0

    static func parse(_ value: String?) -> Date? { StoryBursts.parseTime(value) }

    static func gapSeconds(_ left: StoryGroup, _ right: StoryGroup) -> Double? {
        guard let end = parse(left.endedAt) ?? parse(left.startedAt),
            let start = parse(right.startedAt) ?? parse(right.endedAt)
        else { return nil }
        return abs(start.timeIntervalSince(end))
    }

    static func merge(_ left: StoryGroup, _ right: StoryGroup) -> StoryGroup {
        // min/max keep the first of equal values, as Python min/max do.
        var start: (String, Date)?
        for v in [left.startedAt, right.startedAt] {
            if let v, let d = parse(v), start == nil || d < start!.1 { start = (v, d) }
        }
        var end: (String, Date)?
        for v in [left.endedAt, right.endedAt] {
            if let v, let d = parse(v), end == nil || d > end!.1 { end = (v, d) }
        }
        return StoryGroup(
            storyIds: left.storyIds + right.storyIds, unitCount: left.unitCount + right.unitCount,
            startedAt: start?.0, endedAt: end?.0)
    }

    static func smallNeighbor(_ groups: [StoryGroup], _ index: Int) -> Int {
        let candidates = [index - 1, index + 1].filter { $0 >= 0 && $0 < groups.count }
        if candidates.count == 1 { return candidates[0] }
        let previous = candidates[0], following = candidates[1]
        let group = groups[index]
        if parse(group.startedAt) == nil && parse(group.endedAt) == nil { return previous }
        let gapPrevious = gapSeconds(groups[previous], group)
        guard let gapFollowing = gapSeconds(group, groups[following]) else { return previous }
        guard let gapPrev = gapPrevious else { return following }
        return gapFollowing < gapPrev ? following : previous
    }

    static func distribute(_ groups: [StoryGroup], _ spreadCount: Int, _ minPhotos: Int) -> [Int] {
        let target = Double(groups.reduce(0) { $0 + $1.unitCount }) / Double(spreadCount)
        let count = groups.count
        let maxEach = spreadCount - (count - 1)

        func cost(_ group: StoryGroup, _ spreads: Int) -> Double {
            let diff = Double(group.unitCount) / Double(spreads) - target
            let value = Double(spreads) * (diff * diff)
            let missing = spreads * minPhotos - group.unitCount
            return value + missingUnitPenalty * Double(max(0, missing))
        }

        let inf = Double.infinity
        var best = [[Double]](repeating: [Double](repeating: inf, count: spreadCount + 1), count: count + 1)
        var choice = [[Int]](repeating: [Int](repeating: 0, count: spreadCount + 1), count: count + 1)
        best[0][0] = 0.0
        for (offset, group) in groups.enumerated() {
            let i = offset + 1
            for used in stride(from: i, through: spreadCount, by: 1) {
                let top = min(maxEach, used - (i - 1))
                for spreads in stride(from: 1, through: top, by: 1) {
                    let previous = best[i - 1][used - spreads]
                    if previous == inf { continue }
                    let total = previous + cost(group, spreads)
                    if total < best[i][used] {
                        best[i][used] = total
                        choice[i][used] = spreads
                    }
                }
            }
        }
        var result = [Int](repeating: 0, count: count)
        var used = spreadCount
        for i in stride(from: count, through: 1, by: -1) {
            result[i - 1] = choice[i][used]
            used -= result[i - 1]
        }
        return result
    }

    public static func allocateSpreads(
        _ groups: [StoryGroup], spreadCount: Int, minPhotos: Int, maxPhotos: Int
    ) throws -> [Allocation] {
        if spreadCount < 1 { throw AilbumError.invalid("spread_count must be at least 1") }
        var merged = groups
        if merged.isEmpty { return [] }

        while merged.count > 1 {
            let small = merged.indices.filter { merged[$0].unitCount < minPhotos }
            if small.isEmpty { break }
            var index = small[0]
            for i in small where merged[i].unitCount < merged[index].unitCount { index = i }
            let other = smallNeighbor(merged, index)
            let low = min(index, other), high = max(index, other)
            merged.replaceSubrange(low...high, with: [merge(merged[low], merged[high])])
        }

        while merged.count > spreadCount {
            let sums = (0..<(merged.count - 1)).map { merged[$0].unitCount + merged[$0 + 1].unitCount }
            let low = sums.firstIndex(of: sums.min()!)!
            merged.replaceSubrange(low...(low + 1), with: [merge(merged[low], merged[low + 1])])
        }

        let spreads = distribute(merged, spreadCount, minPhotos)
        return zip(merged, spreads).map {
            Allocation(storyIds: $0.storyIds, unitCount: $0.unitCount, spreads: $1, merged: $0.storyIds.count > 1)
        }
    }
}
