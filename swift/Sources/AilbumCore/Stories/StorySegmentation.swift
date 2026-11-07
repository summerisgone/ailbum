import Foundation

/// Port of `_segment_bursts`, `_refine_change_points`, `_fallback_time_groups`
/// (src/ailbum/stories.py).
public enum StorySegmentation {
    static let segmentPenalty = 0.52
    static let timeWeight = 0.0
    static let changePointThreshold = 0.68

    /// Half-open burst index ranges, as `_segment_bursts` slices them.
    public static func segment(_ bursts: [StoryBurst], continuityMinutes: Int, maxDurationHours: Int) -> [(Int, Int)] {
        let count = bursts.count
        if count == 0 { return [] }
        if count == 1 { return [(0, 1)] }
        let vectors = bursts.map { $0.vector ?? [] }
        let dim = vectors[0].count
        var gaps: [Double] = []
        for i in 1..<count { gaps.append(bursts[i].startedAt.timeIntervalSince(bursts[i - 1].endedAt) / 60) }
        var hardPrefix = [0]
        var timePrefix = [0.0]
        for i in 0..<(count - 1) {
            let hard = gaps[i] > Double(continuityMinutes)
                || StoryBursts.largeGeographicJump(bursts[i], bursts[i + 1], gap: gaps[i])
            hardPrefix.append(hardPrefix[i] + (hard ? 1 : 0))
            timePrefix.append(timePrefix[i] + max(0.0, log1p(gaps[i]) - log1p(StoryBursts.burstMinutes)))
        }
        var cumulative = [[Double](repeating: 0, count: dim)]
        for v in vectors {
            var next = cumulative[cumulative.count - 1]
            for k in 0..<dim { next[k] += v[k] }
            cumulative.append(next)
        }

        var costs = [[Double]](repeating: [Double](repeating: .infinity, count: count), count: count)
        for end in 0..<count {
            for start in 0...end {
                var sq = 0.0
                for k in 0..<dim {
                    let d = cumulative[end + 1][k] - cumulative[start][k]
                    sq += d * d
                }
                let dispersion = Double(end - start + 1) - sq.squareRoot()
                let span = bursts[end].endedAt.timeIntervalSince(bursts[start].startedAt) / 3600
                let crosses = hardPrefix[end] - hardPrefix[start] > 0
                if span <= Double(maxDurationHours) && !crosses {
                    costs[start][end] = dispersion + timeWeight * (timePrefix[end] - timePrefix[start])
                }
            }
        }

        var best = [Double](repeating: .infinity, count: count + 1)
        var previous = [Int](repeating: -1, count: count + 1)
        best[0] = 0
        for end in 1...count {
            var bestStart = 0
            var bestValue = Double.infinity
            for start in 0..<end {
                let candidate = best[start] + costs[start][end - 1] + segmentPenalty
                if candidate < bestValue { bestValue = candidate; bestStart = start }
            }
            best[end] = bestValue
            previous[end] = bestStart
        }

        var ranges: [(Int, Int)] = []
        var end = count
        while end > 0 {
            let start = previous[end]
            ranges.append((start, end))
            end = start
        }
        ranges.reverse()
        return refineChangePoints(ranges, bursts, gaps)
    }

    static func refineChangePoints(_ ranges: [(Int, Int)], _ bursts: [StoryBurst], _ gaps: [Double]) -> [(Int, Int)] {
        var refined: [(Int, Int)] = []
        for (start, end) in ranges {
            if !(4...8).contains(end - start) {
                refined.append((start, end))
                continue
            }
            var candidates: [(Double, Int)] = []
            for boundary in (start + 1)..<max(start + 1, end - 2) {
                let direct = StoryBursts.vectorDistance(
                    StoryBursts.visualVector(bursts[boundary]), StoryBursts.visualVector(bursts[boundary + 1]))
                let leftRange = max(start, boundary - 2)...boundary
                let rightRange = (boundary + 1)..<min(end, boundary + 4)
                let context = StoryBursts.vectorDistance(
                    StoryBursts.meanVector(leftRange.map { StoryBursts.visualVector(bursts[$0]) }),
                    StoryBursts.meanVector(rightRange.map { StoryBursts.visualVector(bursts[$0]) }))
                let semantic = StoryBursts.vectorDistance(
                    StoryBursts.meanVector(leftRange.map { bursts[$0].semanticVector }),
                    StoryBursts.meanVector(rightRange.map { bursts[$0].semanticVector }))
                let leftFace = leftRange.map { bursts[$0].faceRate }.reduce(0, +) / Double(leftRange.count)
                let rightFace = rightRange.map { bursts[$0].faceRate }.reduce(0, +) / Double(rightRange.count)
                let faceChange = abs(leftFace - rightFace)
                let timeSignal = log1p(gaps[boundary]) / log1p(360.0)
                let score = direct + context + 0.35 * timeSignal + 0.25 * semantic + 0.20 * faceChange
                if score >= changePointThreshold && direct >= 0.30 && context >= 0.23 {
                    candidates.append((score, boundary + 1))
                }
            }
            if var top = candidates.first {
                for c in candidates where c.0 > top.0 || (c.0 == top.0 && c.1 > top.1) { top = c }
                refined.append((start, top.1))
                refined.append((top.1, end))
            } else {
                refined.append((start, end))
            }
        }
        return refined
    }

    public static func fallbackTimeGroups(
        _ photos: [StoryPhoto], parsed: [String: Date?], gapMinutes: Int, continuityMinutes: Int,
        maxDurationHours: Int
    ) -> [[StoryPhoto]] {
        var groups: [[StoryPhoto]] = []
        for photo in photos {
            guard let last = groups.last, let previous = last.last else {
                groups.append([photo])
                continue
            }
            guard let currentEntry = parsed[photo.photoId], let current = currentEntry,
                let previousEntry = parsed[previous.photoId], let previousTime = previousEntry,
                let firstEntry = parsed[last[0].photoId], let first = firstEntry
            else { preconditionFailure("photo has no parsed time") }
            let gap = current.timeIntervalSince(previousTime) / 60
            let duration = current.timeIntervalSince(first) / 3600
            let distance = StoryBursts.distanceKm(previous, photo)
            let shared = !previous.people.isDisjoint(with: photo.people)
            let near = distance.map { $0 <= 3 } ?? false
            let far = distance.map { $0 > 25 } ?? false
            let continues = (0 <= gap && gap <= Double(gapMinutes) && duration <= Double(maxDurationHours)
                && !(far && gap > 15))
                || (Double(gapMinutes) < gap && gap <= Double(continuityMinutes)
                    && duration <= Double(maxDurationHours) && (shared || near))
            if continues { groups[groups.count - 1].append(photo) } else { groups.append([photo]) }
        }
        return groups
    }
}
